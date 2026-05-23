#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - File Logging

static NSString *_logPath = nil;

static void TWABLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[TwitchAdBlock] %@", msg);

    if (!_logPath) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        _logPath = paths.count > 0
            ? [paths[0] stringByAppendingPathComponent:@"TwitchAdBlock.log"]
            : @"/tmp/TwitchAdBlock.log";
    }

    NSString *line = [NSString stringWithFormat:@"%@: %@\n",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
                                       dateStyle:NSDateFormatterShortStyle
                                       timeStyle:NSDateFormatterMediumStyle], msg];

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:_logPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        [line writeToFile:_logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

#pragma mark - Stored IMPs

static IMP _orig_setHTTPBody = NULL;
static IMP _orig_dataTaskWithRequest = NULL;
static IMP _orig_dataTaskWithRequestCompletion = NULL;
static IMP _orig_didReceiveData = NULL;

#pragma mark - Utility

static BOOL swizzleMethod(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

#pragma mark - GQL Platform Spoofing

static NSData *twab_spoofGQLBody(NSData *body, NSURL *url) {
    if (!body || !url) return body;

    NSString *host = url.host;
    NSString *path = url.path;

    // Broad match - catch any twitch GQL endpoint
    BOOL isGQL = NO;
    if (host && path) {
        isGQL = ([host containsString:@"twitch.tv"] && [path containsString:@"gql"]) ||
                [host containsString:@"gql.twitch"];
    }

    if (!isGQL) return body;

    TWABLog(@"=== GQL BODY INTERCEPTED via setHTTPBody ===");
    TWABLog(@"URL: %@", url.absoluteString);

    // Log raw body preview
    NSString *bodyStr = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    if (bodyStr) {
        TWABLog(@"Body (%lu bytes): %.500s", (unsigned long)body.length, bodyStr.UTF8String);
    }

    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:body
                                              options:NSJSONReadingMutableContainers
                                                error:&error];
    if (!json || error) {
        TWABLog(@"JSON parse error: %@", error);
        return body;
    }

    NSString *platform = [NSUUID UUID].UUIDString;

    void (^processOp)(NSMutableDictionary *) = ^(NSMutableDictionary *op) {
        if (![op isKindOfClass:NSMutableDictionary.class]) return;

        NSString *opName = op[@"operationName"];
        TWABLog(@"  Operation: %@", opName);

        if (!opName) return;

        // Match ANY access token operation
        BOOL isToken = [opName containsString:@"AccessToken"] ||
                       [opName containsString:@"accessToken"] ||
                       [opName containsString:@"PlaybackAccessToken"] ||
                       [opName containsString:@"StreamAccessToken"] ||
                       [opName containsString:@"VodAccessToken"];

        if (!isToken) return;

        TWABLog(@"  MATCHED token operation: %@", opName);

        NSMutableDictionary *variables = op[@"variables"];
        if (!variables) {
            TWABLog(@"  WARNING: no variables key");
            return;
        }

        TWABLog(@"  variables keys: %@", [variables allKeys]);
        TWABLog(@"  variables: %@", variables);

        // Try every known location for platform
        NSMutableDictionary *params = variables[@"params"];
        if (params && [params isKindOfClass:NSMutableDictionary.class]) {
            TWABLog(@"  params keys: %@", [params allKeys]);
            params[@"platform"] = platform;
            TWABLog(@"  SPOOFED params.platform");
            return;
        }

        NSMutableDictionary *tokenParams = variables[@"tokenParams"];
        if (tokenParams && [tokenParams isKindOfClass:NSMutableDictionary.class]) {
            TWABLog(@"  tokenParams keys: %@", [tokenParams allKeys]);
            tokenParams[@"platform"] = platform;
            TWABLog(@"  SPOOFED tokenParams.platform");
            return;
        }

        if (variables[@"platform"]) {
            variables[@"platform"] = platform;
            TWABLog(@"  SPOOFED variables.platform directly");
            return;
        }

        // Force inject
        TWABLog(@"  No known platform location, force injecting params.platform");
        params = [NSMutableDictionary dictionary];
        params[@"platform"] = platform;
        variables[@"params"] = params;
    };

    if ([json isKindOfClass:NSMutableDictionary.class]) {
        processOp(json);
    } else if ([json isKindOfClass:NSMutableArray.class]) {
        for (id op in (NSMutableArray *)json) {
            processOp(op);
        }
    }

    NSData *modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    if (!error && modifiedData) {
        TWABLog(@"=== Body modified successfully ===");
        return modifiedData;
    }

    return body;
}

#pragma mark - NSMutableURLRequest setHTTPBody: Hook

// This is the KEY hook. RCT calls setHTTPBody: on the request
// AFTER creating it. By hooking here, we catch the body at the
// exact moment it's set, regardless of when dataTaskWithRequest: is called.

static void hooked_setHTTPBody(id self, SEL _cmd, NSData *body) {
    NSData *modifiedBody = body;

    if (body && [self isKindOfClass:[NSMutableURLRequest class]]) {
        NSURL *url = [(NSMutableURLRequest *)self URL];
        modifiedBody = twab_spoofGQLBody(body, url);
    }

    ((void (*)(id, SEL, NSData *))_orig_setHTTPBody)(self, _cmd, modifiedBody);
}

#pragma mark - NSURLSession Hooks (backup + logging)

static NSURLSessionDataTask *hooked_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    if (request.URL) {
        TWABLog(@"dataTaskWithRequest: %@ %@ (body: %lu bytes)",
                request.HTTPMethod, request.URL.host,
                (unsigned long)request.HTTPBody.length);
    }

    // Also try spoofing here in case body was set before the task was created
    if (request.HTTPBody && [request isKindOfClass:NSMutableURLRequest.class]) {
        NSData *spoofed = twab_spoofGQLBody(request.HTTPBody, request.URL);
        if (spoofed != request.HTTPBody) {
            ((NSMutableURLRequest *)request).HTTPBody = spoofed;
        }
    }

    return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *))_orig_dataTaskWithRequest)(self, _cmd, request);
}

static NSURLSessionDataTask *hooked_dataTaskWithRequestCompletion(
    id self, SEL _cmd, NSURLRequest *request,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {

    if (request.URL) {
        TWABLog(@"dataTaskWithRequest:completionHandler: %@ %@ (body: %lu bytes)",
                request.HTTPMethod, request.URL.host,
                (unsigned long)request.HTTPBody.length);
    }

    if (request.HTTPBody && [request isKindOfClass:NSMutableURLRequest.class]) {
        NSData *spoofed = twab_spoofGQLBody(request.HTTPBody, request.URL);
        if (spoofed != request.HTTPBody) {
            ((NSMutableURLRequest *)request).HTTPBody = spoofed;
        }
    }

    return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, id))_orig_dataTaskWithRequestCompletion)(
        self, _cmd, request, completionHandler);
}

#pragma mark - RCTHTTPRequestHandler Hook

static void hooked_didReceiveData(id self, SEL _cmd, id session, id dataTask, NSData *data) {
    // Response filtering for FeedAd
    NSURLRequest *req = [dataTask currentRequest];
    if (req && data && [req.URL.host containsString:@"twitch.tv"]) {
        NSError *error;
        id json = [NSJSONSerialization JSONObjectWithData:data
                                                  options:NSJSONReadingMutableContainers
                                                    error:&error];
        if (json && !error) {
            void (^filterFeedAds)(NSMutableDictionary *) = ^(NSMutableDictionary *dict) {
                NSMutableDictionary *feedItems = dict[@"data"][@"feedItems"];
                if (feedItems && feedItems[@"edges"]) {
                    NSArray *edges = feedItems[@"edges"];
                    NSArray *filtered = [edges filteredArrayUsingPredicate:
                        [NSPredicate predicateWithFormat:@"node.__typename != 'FeedAd'"]];
                    if (filtered.count != edges.count) {
                        feedItems[@"edges"] = filtered;
                        TWABLog(@"Filtered %lu FeedAd(s)", (unsigned long)(edges.count - filtered.count));
                    }
                }
            };

            if ([json isKindOfClass:NSMutableArray.class]) {
                for (id item in (NSMutableArray *)json) {
                    if ([item isKindOfClass:NSMutableDictionary.class]) filterFeedAds(item);
                }
            } else if ([json isKindOfClass:NSMutableDictionary.class]) {
                filterFeedAds((NSMutableDictionary *)json);
            }

            NSData *modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
            if (!error && modifiedData) data = modifiedData;
        }
    }

    ((void (*)(id, SEL, id, id, NSData *))_orig_didReceiveData)(
        self, _cmd, session, dataTask, data);
}

#pragma mark - Constructor

__attribute__((constructor))
static void TwitchAdBlockInit(void) {
    TWABLog(@"=== TwitchAdBlock INITIALIZING ===");

    // PRIMARY HOOK: setHTTPBody: on NSMutableURLRequest
    // This catches the body at the exact moment it's set
    Class reqClass = [NSMutableURLRequest class];
    BOOL h0 = swizzleMethod(reqClass, @selector(setHTTPBody:),
                  (IMP)hooked_setHTTPBody, &_orig_setHTTPBody);
    TWABLog(@"Hooked setHTTPBody: %@", h0 ? @"YES" : @"NO");

    // BACKUP HOOKS: NSURLSession dataTaskWithRequest:
    Class sessionClass = [NSURLSession class];
    BOOL h1 = swizzleMethod(sessionClass, @selector(dataTaskWithRequest:),
                  (IMP)hooked_dataTaskWithRequest, &_orig_dataTaskWithRequest);
    TWABLog(@"Hooked dataTaskWithRequest: %@", h1 ? @"YES" : @"NO");

    BOOL h2 = swizzleMethod(sessionClass, @selector(dataTaskWithRequest:completionHandler:),
                  (IMP)hooked_dataTaskWithRequestCompletion, &_orig_dataTaskWithRequestCompletion);
    TWABLog(@"Hooked dataTaskWithRequest:completionHandler: %@", h2 ? @"YES" : @"NO");

    // Response filtering
    Class rctHandler = NSClassFromString(@"RCTHTTPRequestHandler");
    if (rctHandler) {
        BOOL h3 = swizzleMethod(rctHandler, @selector(URLSession:dataTask:didReceiveData:),
                      (IMP)hooked_didReceiveData, &_orig_didReceiveData);
        TWABLog(@"Hooked RCTHTTPRequestHandler didReceiveData: %@", h3 ? @"YES" : @"NO");
    } else {
        TWABLog(@"WARNING: RCTHTTPRequestHandler NOT FOUND");
    }

    TWABLog(@"=== TwitchAdBlock READY — log: %@ ===", _logPath);
}
