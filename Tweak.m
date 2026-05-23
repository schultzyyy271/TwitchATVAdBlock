#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define PROXY_URL @"https://lb-eu.cdn-perfprod.com"

static IMP _orig_setHTTPBody = NULL;
static IMP _orig_dataTaskWithRequest = NULL;
static IMP _orig_dataTaskWithRequestCompletion = NULL;
static IMP _orig_didReceiveData = NULL;

static BOOL swizzleMethod(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    return YES;
}

#pragma mark - Proxy URL Rewriting

static NSURL *twab_proxyURL(NSURL *originalURL) {
    if (!originalURL || ![originalURL.host isEqualToString:@"usher.ttvnw.net"]) return nil;

    NSURL *proxyBase = [NSURL URLWithString:PROXY_URL];
    if (!proxyBase) return nil;

    // Check if proxy is Luminous v1
    __block BOOL isV1 = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURL *pingURL = [proxyBase URLByAppendingPathComponent:@"ping"];
    [[NSURLSession.sharedSession dataTaskWithRequest:[NSURLRequest requestWithURL:pingURL]
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            isV1 = [r isKindOfClass:NSHTTPURLResponse.class] &&
                   ((NSHTTPURLResponse *)r).statusCode == 200;
            dispatch_semaphore_signal(sem);
        }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 500000000));

    if (!isV1) return nil;

    BOOL isVOD = [originalURL.path.pathComponents[1] isEqualToString:@"vod"];
    NSString *item = [originalURL.lastPathComponent stringByDeletingPathExtension];
    NSString *type = isVOD ? @"vod" : @"playlist";

    return [[proxyBase URLByAppendingPathComponent:type] URLByAppendingPathComponent:item];
}

#pragma mark - GQL Platform Spoofing

static NSData *twab_spoofGQLBody(NSData *body, NSURL *url) {
    if (!body || !url) return body;

    NSString *host = url.host;
    NSString *path = url.path;

    if (!host || !path) return body;
    if (!([host containsString:@"twitch.tv"] && [path containsString:@"gql"])) return body;

    NSError *error;
    id json = [NSJSONSerialization JSONObjectWithData:body
                                              options:NSJSONReadingMutableContainers
                                                error:&error];
    if (!json || error) return body;

    NSString *platform = [NSUUID UUID].UUIDString;

    void (^processOp)(NSMutableDictionary *) = ^(NSMutableDictionary *op) {
        if (![op isKindOfClass:NSMutableDictionary.class]) return;

        NSString *opName = op[@"operationName"];
        if (!opName || ![opName containsString:@"AccessToken"]) return;

        NSMutableDictionary *variables = op[@"variables"];
        if (!variables) return;

        NSMutableDictionary *params = variables[@"params"];
        if (params && [params isKindOfClass:NSMutableDictionary.class]) {
            params[@"platform"] = platform;
            return;
        }

        NSMutableDictionary *tokenParams = variables[@"tokenParams"];
        if (tokenParams && [tokenParams isKindOfClass:NSMutableDictionary.class]) {
            tokenParams[@"platform"] = platform;
            return;
        }

        if (variables[@"platform"]) {
            variables[@"platform"] = platform;
            return;
        }

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
    return (!error && modifiedData) ? modifiedData : body;
}

#pragma mark - Hooks

static void hooked_setHTTPBody(id self, SEL _cmd, NSData *body) {
    NSData *modified = body;
    if (body && [self isKindOfClass:[NSMutableURLRequest class]]) {
        modified = twab_spoofGQLBody(body, [(NSMutableURLRequest *)self URL]);
    }
    ((void (*)(id, SEL, NSData *))_orig_setHTTPBody)(self, _cmd, modified);
}

static NSURLSessionDataTask *hooked_dataTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    // GQL body spoofing
    if (request.HTTPBody && [request isKindOfClass:NSMutableURLRequest.class]) {
        NSData *spoofed = twab_spoofGQLBody(request.HTTPBody, request.URL);
        if (spoofed != request.HTTPBody) {
            ((NSMutableURLRequest *)request).HTTPBody = spoofed;
        }
    }

    // Proxy redirect for usher.ttvnw.net
    if ([request.URL.host isEqualToString:@"usher.ttvnw.net"]) {
        NSURL *proxied = twab_proxyURL(request.URL);
        if (proxied && [request isKindOfClass:NSMutableURLRequest.class]) {
            ((NSMutableURLRequest *)request).URL = proxied;
        } else if (proxied) {
            NSMutableURLRequest *mutableReq = request.mutableCopy;
            mutableReq.URL = proxied;
            request = mutableReq;
        }
    }

    return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *))_orig_dataTaskWithRequest)(self, _cmd, request);
}

static NSURLSessionDataTask *hooked_dataTaskWithRequestCompletion(
    id self, SEL _cmd, NSURLRequest *request,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    // GQL body spoofing
    if (request.HTTPBody && [request isKindOfClass:NSMutableURLRequest.class]) {
        NSData *spoofed = twab_spoofGQLBody(request.HTTPBody, request.URL);
        if (spoofed != request.HTTPBody) {
            ((NSMutableURLRequest *)request).HTTPBody = spoofed;
        }
    }

    // Proxy redirect for usher.ttvnw.net
    if ([request.URL.host isEqualToString:@"usher.ttvnw.net"]) {
        NSURL *proxied = twab_proxyURL(request.URL);
        if (proxied && [request isKindOfClass:NSMutableURLRequest.class]) {
            ((NSMutableURLRequest *)request).URL = proxied;
        } else if (proxied) {
            NSMutableURLRequest *mutableReq = request.mutableCopy;
            mutableReq.URL = proxied;
            request = mutableReq;
        }
    }

    return ((NSURLSessionDataTask *(*)(id, SEL, NSURLRequest *, id))_orig_dataTaskWithRequestCompletion)(
        self, _cmd, request, completionHandler);
}

static void hooked_didReceiveData(id self, SEL _cmd, id session, id dataTask, NSData *data) {
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
                    if (filtered.count != edges.count) feedItems[@"edges"] = filtered;
                }
            };

            if ([json isKindOfClass:NSMutableArray.class]) {
                for (id item in (NSMutableArray *)json)
                    if ([item isKindOfClass:NSMutableDictionary.class]) filterFeedAds(item);
            } else if ([json isKindOfClass:NSMutableDictionary.class]) {
                filterFeedAds((NSMutableDictionary *)json);
            }

            NSData *mod = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
            if (!error && mod) data = mod;
        }
    }
    ((void (*)(id, SEL, id, id, NSData *))_orig_didReceiveData)(self, _cmd, session, dataTask, data);
}

#pragma mark - Constructor

__attribute__((constructor))
static void TwitchAdBlockInit(void) {
    swizzleMethod([NSMutableURLRequest class], @selector(setHTTPBody:),
                  (IMP)hooked_setHTTPBody, &_orig_setHTTPBody);

    Class sc = [NSURLSession class];
    swizzleMethod(sc, @selector(dataTaskWithRequest:),
                  (IMP)hooked_dataTaskWithRequest, &_orig_dataTaskWithRequest);
    swizzleMethod(sc, @selector(dataTaskWithRequest:completionHandler:),
                  (IMP)hooked_dataTaskWithRequestCompletion, &_orig_dataTaskWithRequestCompletion);

    Class rct = NSClassFromString(@"RCTHTTPRequestHandler");
    if (rct) {
        swizzleMethod(rct, @selector(URLSession:dataTask:didReceiveData:),
                      (IMP)hooked_didReceiveData, &_orig_didReceiveData);
    }
}
