#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Stored IMPs

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

static BOOL twab_spoofPlatformInOperation(NSMutableDictionary *operation, NSString *platform) {
    if (![operation isKindOfClass:NSMutableDictionary.class]) return NO;

    NSString *opName = operation[@"operationName"];
    NSString *query = operation[@"query"];

    // tvOS uses PlaybackAccessToken
    BOOL isPlaybackToken = [opName isEqualToString:@"PlaybackAccessToken"];
    // iOS names kept for compatibility
    BOOL isStreamToken = [opName isEqualToString:@"StreamAccessToken"] ||
                         (query && [query containsString:@"StreamAccessToken"]);
    BOOL isVodToken = [opName isEqualToString:@"VodAccessToken"];
    BOOL isClipToken = [opName isEqualToString:@"ClipAccessToken"];

    if (isPlaybackToken || isStreamToken || isVodToken) {
        NSMutableDictionary *variables = operation[@"variables"];
        if (variables) {
            // Try params.platform (standard structure)
            NSMutableDictionary *params = variables[@"params"];
            if (params) {
                params[@"platform"] = platform;
                NSLog(@"[TwitchAdBlock] Spoofed platform in params for %@", opName);
                return YES;
            }
            // Try direct platform key
            if (variables[@"platform"]) {
                variables[@"platform"] = platform;
                NSLog(@"[TwitchAdBlock] Spoofed platform directly for %@", opName);
                return YES;
            }
            // Try setting it anyway
            if (!params) {
                params = [NSMutableDictionary dictionary];
                params[@"platform"] = platform;
                variables[@"params"] = params;
                NSLog(@"[TwitchAdBlock] Created params.platform for %@", opName);
                return YES;
            }
        }
    } else if (isClipToken) {
        NSMutableDictionary *variables = operation[@"variables"];
        if (variables) {
            NSMutableDictionary *tokenParams = variables[@"tokenParams"];
            if (tokenParams) {
                tokenParams[@"platform"] = platform;
                NSLog(@"[TwitchAdBlock] Spoofed platform for ClipAccessToken");
                return YES;
            }
        }
    }

    return NO;
}

static NSData *twab_spoofRequestBody(NSData *body, NSURLRequest *request) {
    if (!body || !request) return body;

    NSString *host = request.URL.host;
    NSString *path = request.URL.path;

    if (![host isEqualToString:@"gql.twitch.tv"] || ![path isEqualToString:@"/gql"]) {
        return body;
    }

    NSLog(@"[TwitchAdBlock] Intercepted GQL request to %@%@", host, path);

    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:body
                                              options:NSJSONReadingMutableContainers
                                                error:&error];
    if (!json || error) {
        NSLog(@"[TwitchAdBlock] Failed to parse GQL body: %@", error);
        return body;
    }

    NSString *platform = [NSUUID UUID].UUIDString;
    BOOL spoofed = NO;

    if ([json isKindOfClass:NSMutableDictionary.class]) {
        NSString *opName = ((NSDictionary *)json)[@"operationName"];
        NSLog(@"[TwitchAdBlock] GQL operation: %@", opName);
        spoofed = twab_spoofPlatformInOperation(json, platform);
    } else if ([json isKindOfClass:NSMutableArray.class]) {
        for (id operation in (NSMutableArray *)json) {
            if ([operation isKindOfClass:NSMutableDictionary.class]) {
                NSString *opName = ((NSDictionary *)operation)[@"operationName"];
                NSLog(@"[TwitchAdBlock] GQL batch operation: %@", opName);
            }
            if (twab_spoofPlatformInOperation(operation, platform)) {
                spoofed = YES;
            }
        }
    }

    if (spoofed) {
        NSData *modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
        if (!error && modifiedData) return modifiedData;
    }

    return body;
}

static NSData *twab_filterResponseBody(NSData *body, NSURLRequest *request) {
    if (!body || !request) return body;
    if (![request.URL.host isEqualToString:@"gql.twitch.tv"] ||
        ![request.URL.path isEqualToString:@"/gql"]) {
        return body;
    }

    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:body
                                              options:NSJSONReadingMutableContainers
                                                error:&error];
    if (!json || error) return body;

    void (^filterFeedAds)(NSMutableDictionary *) = ^(NSMutableDictionary *dict) {
        NSMutableDictionary *feedItems = dict[@"data"][@"feedItems"];
        if (feedItems && feedItems[@"edges"]) {
            NSArray *edges = feedItems[@"edges"];
            NSArray *filtered = [edges filteredArrayUsingPredicate:
                [NSPredicate predicateWithFormat:@"node.__typename != 'FeedAd'"]];
            if (filtered.count != edges.count) {
                feedItems[@"edges"] = filtered;
                NSLog(@"[TwitchAdBlock] Filtered %lu FeedAd(s)",
                      (unsigned long)(edges.count - filtered.count));
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
    return (!error && modifiedData) ? modifiedData : body;
}

#pragma mark - NSURLSession Hooks

static NSURLSessionDataTask *hooked_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    if (![request isKindOfClass:NSMutableURLRequest.class]) {
        request = request.mutableCopy;
    }
    ((NSMutableURLRequest *)request).HTTPBody =
        twab_spoofRequestBody(request.HTTPBody, request);

    return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *))_orig_dataTaskWithRequest)(self, _cmd, request);
}

static NSURLSessionDataTask *hooked_dataTaskWithRequestCompletion(
    id self, SEL _cmd, NSURLRequest *request,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {

    if (![request isKindOfClass:NSMutableURLRequest.class]) {
        request = request.mutableCopy;
    }
    ((NSMutableURLRequest *)request).HTTPBody =
        twab_spoofRequestBody(request.HTTPBody, request);

    return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, id))_orig_dataTaskWithRequestCompletion)(
        self, _cmd, request, completionHandler);
}

#pragma mark - RCTHTTPRequestHandler Hook

static void hooked_didReceiveData(id self, SEL _cmd, id session, id dataTask, NSData *data) {
    NSURL *url = [[dataTask currentRequest] URL] ?: [[dataTask originalRequest] URL];
    NSData *filtered = twab_filterResponseBody(data, [dataTask currentRequest]);
    ((void (*)(id, SEL, id, id, NSData *))_orig_didReceiveData)(
        self, _cmd, session, dataTask, filtered);
}

#pragma mark - Constructor

__attribute__((constructor))
static void TwitchAdBlockInit(void) {
    NSLog(@"[TwitchAdBlock] Initializing TwitchAdBlock for tvOS");

    // Hook NSURLSession dataTaskWithRequest:
    Class sessionClass = [NSURLSession class];
    swizzleMethod(sessionClass, @selector(dataTaskWithRequest:),
                  (IMP)hooked_dataTaskWithRequest, &_orig_dataTaskWithRequest);
    NSLog(@"[TwitchAdBlock] Hooked dataTaskWithRequest:");

    swizzleMethod(sessionClass, @selector(dataTaskWithRequest:completionHandler:),
                  (IMP)hooked_dataTaskWithRequestCompletion, &_orig_dataTaskWithRequestCompletion);
    NSLog(@"[TwitchAdBlock] Hooked dataTaskWithRequest:completionHandler:");

    // Hook RCTHTTPRequestHandler for response filtering
    Class rctHandler = NSClassFromString(@"RCTHTTPRequestHandler");
    if (rctHandler) {
        swizzleMethod(rctHandler, @selector(URLSession:dataTask:didReceiveData:),
                      (IMP)hooked_didReceiveData, &_orig_didReceiveData);
        NSLog(@"[TwitchAdBlock] Hooked RCTHTTPRequestHandler didReceiveData:");
    }

    NSLog(@"[TwitchAdBlock] All hooks installed - GQL platform spoofing ENABLED");
}
