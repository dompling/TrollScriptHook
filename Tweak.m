//
//  Tweak.m
//  TrollScriptHook
//
//  通知拦截 Hook - 纯 Objective-C Runtime 实现
//  不依赖 CydiaSubstrate，可直接通过 insert_dylib 注入
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <notify.h>

// MARK: - Constants

static NSString * const kTrollScriptNotificationName = @"com.trollscript.hook.notification";
static NSString * const kTrollScriptAppLaunchedName = @"com.trollscript.hook.app.launched";
static NSString * const kTrollScriptSharedPath = @"/var/mobile/Library/TrollScript/HookData";
static NSString * const kPendingNotificationsFile = @"pending_notifications.json";
static NSString * const kLatestEventFile = @"latest_event.json";
static const NSUInteger kMaxPendingNotifications = 100;

// MARK: - Thread Safety

static dispatch_queue_t _notificationQueue;
static dispatch_queue_t getNotificationQueue(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _notificationQueue = dispatch_queue_create("com.trollscript.hook.queue", DISPATCH_QUEUE_SERIAL);
    });
    return _notificationQueue;
}

// MARK: - Safe Bundle ID

static NSString *getSafeBundleID(void) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    return bundleID.length > 0 ? bundleID : @"unknown";
}

// MARK: - Directory Management

static BOOL ensureDirectoryExists(void) {
    static BOOL directoryExists = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;

        if (![fm fileExistsAtPath:kTrollScriptSharedPath]) {
            directoryExists = [fm createDirectoryAtPath:kTrollScriptSharedPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&error];
            if (error) {
                NSLog(@"[TrollScriptHook] Failed to create directory: %@", error.localizedDescription);
            }
        } else {
            directoryExists = YES;
        }
    });
    return directoryExists;
}

// MARK: - Safe JSON Serialization

static NSData *safeJSONSerialize(id object) {
    if (!object) return nil;

    @try {
        if (![NSJSONSerialization isValidJSONObject:object]) {
            NSLog(@"[TrollScriptHook] Invalid JSON object");
            return nil;
        }

        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                       options:0
                                                         error:&error];
        if (error) {
            NSLog(@"[TrollScriptHook] JSON serialization error: %@", error.localizedDescription);
            return nil;
        }
        return data;
    } @catch (NSException *e) {
        NSLog(@"[TrollScriptHook] JSON serialization exception: %@", e);
        return nil;
    }
}

static id safeJSONDeserialize(NSData *data) {
    if (!data || data.length == 0) return nil;

    @try {
        NSError *error = nil;
        id object = [NSJSONSerialization JSONObjectWithData:data
                                                    options:NSJSONReadingMutableContainers
                                                      error:&error];
        if (error) {
            NSLog(@"[TrollScriptHook] JSON deserialization error: %@", error.localizedDescription);
            return nil;
        }
        return object;
    } @catch (NSException *e) {
        NSLog(@"[TrollScriptHook] JSON deserialization exception: %@", e);
        return nil;
    }
}

// MARK: - File Operations (Thread Safe)

static void writePendingNotificationAsync(NSDictionary *info) {
    if (!info) return;

    NSDictionary *infoCopy = [info copy];

    dispatch_async(getNotificationQueue(), ^{
        @autoreleasepool {
            if (!ensureDirectoryExists()) {
                NSLog(@"[TrollScriptHook] Directory not available, skipping write");
                return;
            }

            NSString *filePath = [kTrollScriptSharedPath stringByAppendingPathComponent:kPendingNotificationsFile];
            NSFileManager *fm = [NSFileManager defaultManager];
            NSMutableArray *pending = [NSMutableArray array];

            if ([fm fileExistsAtPath:filePath]) {
                NSData *existingData = [NSData dataWithContentsOfFile:filePath];
                NSArray *existingArray = safeJSONDeserialize(existingData);
                if ([existingArray isKindOfClass:[NSArray class]]) {
                    [pending addObjectsFromArray:existingArray];
                }
            }

            [pending addObject:infoCopy];

            while (pending.count > kMaxPendingNotifications) {
                [pending removeObjectAtIndex:0];
            }

            NSData *jsonData = safeJSONSerialize(pending);
            if (jsonData) {
                NSError *writeError = nil;
                BOOL success = [jsonData writeToFile:filePath
                                             options:NSDataWritingAtomic
                                               error:&writeError];
                if (!success) {
                    NSLog(@"[TrollScriptHook] Failed to write notifications: %@", writeError.localizedDescription);
                }
            }

            notify_post([kTrollScriptNotificationName UTF8String]);
        }
    });
}

static void writeEventAsync(NSDictionary *event) {
    if (!event) return;

    NSDictionary *eventCopy = [event copy];

    dispatch_async(getNotificationQueue(), ^{
        @autoreleasepool {
            if (!ensureDirectoryExists()) return;

            NSString *eventPath = [kTrollScriptSharedPath stringByAppendingPathComponent:kLatestEventFile];
            NSData *data = safeJSONSerialize(eventCopy);
            if (data) {
                [data writeToFile:eventPath options:NSDataWritingAtomic error:nil];
            }
        }
    });
}

// MARK: - Notification Info Builder

static NSDictionary *buildNotificationInfo(UNNotificationContent *content,
                                           NSString *identifier,
                                           NSString *type,
                                           NSDictionary *extraInfo) {
    if (!content) return nil;

    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    info[@"bundleID"] = getSafeBundleID();
    info[@"identifier"] = identifier ?: @"";
    info[@"title"] = content.title ?: @"";
    info[@"subtitle"] = content.subtitle ?: @"";
    info[@"body"] = content.body ?: @"";
    info[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    info[@"type"] = type ?: @"unknown";

    if (content.badge && [content.badge isKindOfClass:[NSNumber class]]) {
        info[@"badge"] = content.badge;
    } else {
        info[@"badge"] = @0;
    }

    if (content.userInfo.count > 0) {
        @try {
            NSDictionary *userInfo = content.userInfo;
            if ([NSJSONSerialization isValidJSONObject:userInfo]) {
                info[@"userInfo"] = userInfo;
            }
        } @catch (NSException *e) {
            // Ignore non-serializable userInfo
        }
    }

    if (extraInfo) {
        [info addEntriesFromDictionary:extraInfo];
    }

    return [info copy];
}

// MARK: - Original IMP Storage

static NSMutableDictionary<NSString *, NSValue *> *_originalIMPs = nil;

static void storeOriginalIMP(NSString *key, IMP imp) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _originalIMPs = [NSMutableDictionary dictionary];
    });
    @synchronized (_originalIMPs) {
        _originalIMPs[key] = [NSValue valueWithPointer:imp];
    }
}

static IMP getOriginalIMP(NSString *key) {
    @synchronized (_originalIMPs) {
        NSValue *value = _originalIMPs[key];
        return value ? [value pointerValue] : NULL;
    }
}

// MARK: - Swizzled UNUserNotificationCenter Methods

static void (*original_setDelegate)(id, SEL, id<UNUserNotificationCenterDelegate>);
static void swizzled_setDelegate(id self, SEL _cmd, id<UNUserNotificationCenterDelegate> delegate) {
    if (delegate) {
        Class delegateClass = [delegate class];
        NSString *className = NSStringFromClass(delegateClass);
        NSLog(@"[TrollScriptHook] UNUserNotificationCenter delegate set: %@", className);

        // Hook delegate's willPresentNotification method
        SEL willPresentSel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
        if ([delegate respondsToSelector:willPresentSel]) {
            Method method = class_getInstanceMethod(delegateClass, willPresentSel);
            if (method) {
                NSString *key = [NSString stringWithFormat:@"%@_willPresent", className];
                IMP existingOriginal = getOriginalIMP(key);
                if (!existingOriginal) {
                    IMP originalIMP = method_getImplementation(method);
                    storeOriginalIMP(key, originalIMP);

                    IMP newIMP = imp_implementationWithBlock(^(id _self, UNUserNotificationCenter *center, UNNotification *notification, void (^completionHandler)(UNNotificationPresentationOptions)) {
                        @try {
                            UNNotificationContent *content = notification.request.content;
                            NSString *identifier = notification.request.identifier;

                            NSDictionary *info = buildNotificationInfo(content, identifier, @"remote_foreground", nil);
                            if (info) {
                                writePendingNotificationAsync(info);
                                NSLog(@"[TrollScriptHook] Foreground notification intercepted: %@", content.title ?: @"(no title)");
                            }
                        } @catch (NSException *e) {
                            NSLog(@"[TrollScriptHook] Error in willPresentNotification: %@", e);
                        }

                        IMP orig = getOriginalIMP(key);
                        if (orig) {
                            ((void (*)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions)))orig)(_self, willPresentSel, center, notification, completionHandler);
                        } else if (completionHandler) {
                            UNNotificationPresentationOptions options = UNNotificationPresentationOptionSound;
                            if (@available(iOS 14.0, *)) {
                                options |= UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList;
                            }
                            completionHandler(options);
                        }
                    });

                    method_setImplementation(method, newIMP);
                    NSLog(@"[TrollScriptHook] Hooked willPresentNotification on %@", className);
                }
            }
        }

        // Hook delegate's didReceiveNotificationResponse method
        SEL didReceiveSel = @selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:);
        if ([delegate respondsToSelector:didReceiveSel]) {
            Method method = class_getInstanceMethod(delegateClass, didReceiveSel);
            if (method) {
                NSString *key = [NSString stringWithFormat:@"%@_didReceive", className];
                IMP existingOriginal = getOriginalIMP(key);
                if (!existingOriginal) {
                    IMP originalIMP = method_getImplementation(method);
                    storeOriginalIMP(key, originalIMP);

                    IMP newIMP = imp_implementationWithBlock(^(id _self, UNUserNotificationCenter *center, UNNotificationResponse *response, void (^completionHandler)(void)) {
                        @try {
                            UNNotificationContent *content = response.notification.request.content;
                            NSString *identifier = response.notification.request.identifier;

                            NSDictionary *extra = @{@"actionIdentifier": response.actionIdentifier ?: @""};
                            NSDictionary *info = buildNotificationInfo(content, identifier, @"response", extra);

                            if (info) {
                                writePendingNotificationAsync(info);
                                NSLog(@"[TrollScriptHook] Notification response intercepted");
                            }
                        } @catch (NSException *e) {
                            NSLog(@"[TrollScriptHook] Error in didReceiveResponse: %@", e);
                        }

                        IMP orig = getOriginalIMP(key);
                        if (orig) {
                            ((void (*)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void)))orig)(_self, didReceiveSel, center, response, completionHandler);
                        } else if (completionHandler) {
                            completionHandler();
                        }
                    });

                    method_setImplementation(method, newIMP);
                    NSLog(@"[TrollScriptHook] Hooked didReceiveResponse on %@", className);
                }
            }
        }
    }

    if (original_setDelegate) {
        original_setDelegate(self, _cmd, delegate);
    }
}

static void (*original_addNotificationRequest)(id, SEL, UNNotificationRequest *, void (^)(NSError *));
static void swizzled_addNotificationRequest(id self, SEL _cmd, UNNotificationRequest *request, void (^completionHandler)(NSError *)) {
    @try {
        if (request && request.content) {
            UNNotificationContent *content = request.content;
            NSDictionary *info = buildNotificationInfo(content, request.identifier, @"local", nil);

            if (info) {
                writePendingNotificationAsync(info);
                NSLog(@"[TrollScriptHook] Local notification intercepted: %@", content.title ?: @"(no title)");
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[TrollScriptHook] Error intercepting local notification: %@", e);
    }

    if (original_addNotificationRequest) {
        original_addNotificationRequest(self, _cmd, request, completionHandler);
    }
}

// MARK: - Swizzled UIApplication Methods

static void (*original_registerForRemoteNotifications)(id, SEL);
static void swizzled_registerForRemoteNotifications(id self, SEL _cmd) {
    NSLog(@"[TrollScriptHook] App registered for remote notifications");

    NSDictionary *event = @{
        @"bundleID": getSafeBundleID(),
        @"event": @"registered_remote_notifications",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    writeEventAsync(event);

    if (original_registerForRemoteNotifications) {
        original_registerForRemoteNotifications(self, _cmd);
    }
}

// MARK: - Method Swizzling Helper

static void swizzleMethod(Class cls, SEL originalSel, IMP newIMP, IMP *originalIMPOut) {
    Method method = class_getInstanceMethod(cls, originalSel);
    if (method) {
        *originalIMPOut = method_setImplementation(method, newIMP);
        NSLog(@"[TrollScriptHook] Swizzled %@ on %@", NSStringFromSelector(originalSel), NSStringFromClass(cls));
    } else {
        NSLog(@"[TrollScriptHook] Method not found: %@ on %@", NSStringFromSelector(originalSel), NSStringFromClass(cls));
    }
}

// MARK: - Hook Installation

static void installHooks(void) {
    // Hook UNUserNotificationCenter
    Class notificationCenterClass = [UNUserNotificationCenter class];

    swizzleMethod(notificationCenterClass,
                  @selector(setDelegate:),
                  (IMP)swizzled_setDelegate,
                  (IMP *)&original_setDelegate);

    swizzleMethod(notificationCenterClass,
                  @selector(addNotificationRequest:withCompletionHandler:),
                  (IMP)swizzled_addNotificationRequest,
                  (IMP *)&original_addNotificationRequest);

    // Hook UIApplication
    Class applicationClass = [UIApplication class];

    swizzleMethod(applicationClass,
                  @selector(registerForRemoteNotifications),
                  (IMP)swizzled_registerForRemoteNotifications,
                  (IMP *)&original_registerForRemoteNotifications);
}

// MARK: - Late Hook for Existing Delegate

static void hookExistingDelegate(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), ^{
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        id<UNUserNotificationCenterDelegate> delegate = center.delegate;
        if (delegate) {
            // Trigger the setDelegate hook logic
            swizzled_setDelegate(center, @selector(setDelegate:), delegate);
            NSLog(@"[TrollScriptHook] Late-hooked existing delegate: %@", NSStringFromClass([delegate class]));
        }
    });
}

// MARK: - Constructor

__attribute__((constructor))
static void TrollScriptHook_init(void) {
    @autoreleasepool {
        NSString *bundleID = getSafeBundleID();

        // Skip system apps (except SpringBoard)
        if ([bundleID hasPrefix:@"com.apple."] && ![bundleID isEqualToString:@"com.apple.springboard"]) {
            NSLog(@"[TrollScriptHook] Skipping system app: %@", bundleID);
            return;
        }

        NSLog(@"[TrollScriptHook] ========================================");
        NSLog(@"[TrollScriptHook] Initializing in app: %@", bundleID);
        NSLog(@"[TrollScriptHook] PID: %d", getpid());
        NSLog(@"[TrollScriptHook] ========================================");

        // Ensure directory exists
        ensureDirectoryExists();

        // Install hooks
        installHooks();

        // Send launch notification
        notify_post([kTrollScriptAppLaunchedName UTF8String]);

        // Write launch event
        NSDictionary *event = @{
            @"bundleID": bundleID,
            @"event": @"app_launched",
            @"timestamp": @([[NSDate date] timeIntervalSince1970]),
            @"processID": @(getpid())
        };
        writeEventAsync(event);

        // Hook existing delegate if already set
        hookExistingDelegate();

        NSLog(@"[TrollScriptHook] Initialization complete");
    }
}
