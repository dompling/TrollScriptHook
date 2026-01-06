//
//  Tweak.x
//  TrollScriptHook
//
//  通知拦截 Hook - 注入到目标 App 后拦截通知并转发给 TrollScript
//  重构版本 - 增强稳定性与线程安全
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

    // 复制数据以避免多线程问题
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

            // 读取现有数据
            if ([fm fileExistsAtPath:filePath]) {
                NSData *existingData = [NSData dataWithContentsOfFile:filePath];
                NSArray *existingArray = safeJSONDeserialize(existingData);
                if ([existingArray isKindOfClass:[NSArray class]]) {
                    [pending addObjectsFromArray:existingArray];
                }
            }

            // 添加新通知
            [pending addObject:infoCopy];

            // 限制最大数量（移除最旧的）
            while (pending.count > kMaxPendingNotifications) {
                [pending removeObjectAtIndex:0];
            }

            // 写入文件
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

            // 发送 Darwin 通知
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

    // 基础信息
    info[@"bundleID"] = getSafeBundleID();
    info[@"identifier"] = identifier ?: @"";
    info[@"title"] = content.title ?: @"";
    info[@"subtitle"] = content.subtitle ?: @"";
    info[@"body"] = content.body ?: @"";
    info[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    info[@"type"] = type ?: @"unknown";

    // Badge - 安全处理
    if (content.badge && [content.badge isKindOfClass:[NSNumber class]]) {
        info[@"badge"] = content.badge;
    } else {
        info[@"badge"] = @0;
    }

    // UserInfo - 安全提取可序列化的部分
    if (content.userInfo.count > 0) {
        @try {
            NSDictionary *userInfo = content.userInfo;
            if ([NSJSONSerialization isValidJSONObject:userInfo]) {
                info[@"userInfo"] = userInfo;
            }
        } @catch (NSException *e) {
            // 忽略不可序列化的 userInfo
        }
    }

    // 额外信息
    if (extraInfo) {
        [info addEntriesFromDictionary:extraInfo];
    }

    return [info copy];
}

// MARK: - Associated Object Keys for Original IMPs

static const char kOriginalWillPresentKey;
static const char kOriginalDidReceiveKey;

// MARK: - Original IMP Storage (Per-Class using Associated Objects)

static void setOriginalWillPresentIMP(Class cls, IMP imp) {
    if (cls && imp) {
        objc_setAssociatedObject(cls, &kOriginalWillPresentKey, [NSValue valueWithPointer:imp], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static IMP getOriginalWillPresentIMP(Class cls) {
    if (!cls) return NULL;
    NSValue *value = objc_getAssociatedObject(cls, &kOriginalWillPresentKey);
    return value ? [value pointerValue] : NULL;
}

static void setOriginalDidReceiveIMP(Class cls, IMP imp) {
    if (cls && imp) {
        objc_setAssociatedObject(cls, &kOriginalDidReceiveKey, [NSValue valueWithPointer:imp], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static IMP getOriginalDidReceiveIMP(Class cls) {
    if (!cls) return NULL;
    NSValue *value = objc_getAssociatedObject(cls, &kOriginalDidReceiveKey);
    return value ? [value pointerValue] : NULL;
}

// MARK: - Swizzled Methods

static void swizzled_willPresentNotification(id self, SEL _cmd,
                                              UNUserNotificationCenter *center,
                                              UNNotification *notification,
                                              void (^completionHandler)(UNNotificationPresentationOptions)) {
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

    // 获取该类的原始方法
    IMP originalIMP = getOriginalWillPresentIMP([self class]);

    // 调用原始方法
    if (originalIMP) {
        ((void (*)(id, SEL, UNUserNotificationCenter *, UNNotification *, void (^)(UNNotificationPresentationOptions)))
         originalIMP)(self, _cmd, center, notification, completionHandler);
    } else if (completionHandler) {
        // 默认行为：显示通知 (iOS 14+ only for rootless)
        UNNotificationPresentationOptions options = UNNotificationPresentationOptionSound;
        if (@available(iOS 14.0, *)) {
            options |= UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList;
        }
        completionHandler(options);
    }
}

static void swizzled_didReceiveResponse(id self, SEL _cmd,
                                         UNUserNotificationCenter *center,
                                         UNNotificationResponse *response,
                                         void (^completionHandler)(void)) {
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

    // 获取该类的原始方法
    IMP originalIMP = getOriginalDidReceiveIMP([self class]);

    // 调用原始方法
    if (originalIMP) {
        ((void (*)(id, SEL, UNUserNotificationCenter *, UNNotificationResponse *, void (^)(void)))
         originalIMP)(self, _cmd, center, response, completionHandler);
    } else if (completionHandler) {
        completionHandler();
    }
}

// MARK: - Dynamic Delegate Hooking

static void hookDelegateClass(Class delegateClass) {
    if (!delegateClass) return;

    static NSMutableSet *hookedClasses = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hookedClasses = [NSMutableSet set];
    });

    @synchronized (hookedClasses) {
        NSString *className = NSStringFromClass(delegateClass);
        if ([hookedClasses containsObject:className]) {
            return; // 已经 hook 过
        }
        [hookedClasses addObject:className];
    }

    // Hook willPresentNotification:
    SEL willPresentSel = @selector(userNotificationCenter:willPresentNotification:withCompletionHandler:);
    if (class_respondsToSelector(delegateClass, willPresentSel)) {
        Method originalMethod = class_getInstanceMethod(delegateClass, willPresentSel);
        if (originalMethod) {
            IMP originalIMP = method_setImplementation(originalMethod, (IMP)swizzled_willPresentNotification);
            setOriginalWillPresentIMP(delegateClass, originalIMP);
            NSLog(@"[TrollScriptHook] Hooked willPresentNotification on %@", NSStringFromClass(delegateClass));
        }
    } else {
        // 如果类没有实现该方法，添加一个（不需要存储原始 IMP，因为没有）
        class_addMethod(delegateClass, willPresentSel, (IMP)swizzled_willPresentNotification,
                       "v@:@@?");
        NSLog(@"[TrollScriptHook] Added willPresentNotification to %@", NSStringFromClass(delegateClass));
    }

    // Hook didReceiveNotificationResponse:
    SEL didReceiveSel = @selector(userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:);
    if (class_respondsToSelector(delegateClass, didReceiveSel)) {
        Method originalMethod = class_getInstanceMethod(delegateClass, didReceiveSel);
        if (originalMethod) {
            IMP originalIMP = method_setImplementation(originalMethod, (IMP)swizzled_didReceiveResponse);
            setOriginalDidReceiveIMP(delegateClass, originalIMP);
            NSLog(@"[TrollScriptHook] Hooked didReceiveResponse on %@", NSStringFromClass(delegateClass));
        }
    } else {
        // 如果类没有实现该方法，添加一个（不需要存储原始 IMP，因为没有）
        class_addMethod(delegateClass, didReceiveSel, (IMP)swizzled_didReceiveResponse,
                       "v@:@@?");
        NSLog(@"[TrollScriptHook] Added didReceiveResponse to %@", NSStringFromClass(delegateClass));
    }
}

// MARK: - UNUserNotificationCenter Hook

%hook UNUserNotificationCenter

// Hook 设置 delegate，以便动态 hook delegate 类
- (void)setDelegate:(id<UNUserNotificationCenterDelegate>)delegate {
    if (delegate) {
        Class delegateClass = [delegate class];
        hookDelegateClass(delegateClass);
        NSLog(@"[TrollScriptHook] Delegate set: %@", NSStringFromClass(delegateClass));
    }
    %orig;
}

// Hook 添加本地通知请求
- (void)addNotificationRequest:(UNNotificationRequest *)request
         withCompletionHandler:(void (^)(NSError *))completionHandler {

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

    %orig;
}

// Hook 获取已投递的通知
- (void)getDeliveredNotificationsWithCompletionHandler:(void (^)(NSArray<UNNotification *> *))completionHandler {
    // 创建包装的 completion handler
    void (^wrappedHandler)(NSArray<UNNotification *> *) = ^(NSArray<UNNotification *> *notifications) {
        @try {
            for (UNNotification *notification in notifications) {
                NSDictionary *info = buildNotificationInfo(notification.request.content,
                                                           notification.request.identifier,
                                                           @"delivered",
                                                           nil);
                if (info) {
                    writePendingNotificationAsync(info);
                }
            }
        } @catch (NSException *e) {
            NSLog(@"[TrollScriptHook] Error in getDeliveredNotifications: %@", e);
        }

        // 调用原始的 completionHandler
        if (completionHandler) {
            completionHandler(notifications);
        }
    };

    %orig(wrappedHandler);
}

%end

// MARK: - UIApplication Hook (Backup for Push Notifications)

%hook UIApplication

// Hook 注册远程通知
- (void)registerForRemoteNotifications {
    NSLog(@"[TrollScriptHook] App registered for remote notifications");

    NSDictionary *event = @{
        @"bundleID": getSafeBundleID(),
        @"event": @"registered_remote_notifications",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };
    writeEventAsync(event);

    %orig;
}

// Hook 收到远程通知 token
- (void)setDelegate:(id<UIApplicationDelegate>)delegate {
    %orig;

    if (delegate) {
        NSLog(@"[TrollScriptHook] UIApplication delegate set: %@", NSStringFromClass([delegate class]));
    }
}

%end

// MARK: - AppDelegate Remote Notification Hooks

%hook NSObject

// 尝试 hook application:didReceiveRemoteNotification:fetchCompletionHandler:
- (void)application:(UIApplication *)application
didReceiveRemoteNotification:(NSDictionary *)userInfo
fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completionHandler {

    // 检查是否是 AppDelegate
    if ([self conformsToProtocol:@protocol(UIApplicationDelegate)]) {
        @try {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            info[@"bundleID"] = getSafeBundleID();
            info[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
            info[@"type"] = @"remote_background";

            // 提取推送内容
            NSDictionary *aps = userInfo[@"aps"];
            if (aps) {
                id alert = aps[@"alert"];
                if ([alert isKindOfClass:[NSString class]]) {
                    info[@"body"] = alert;
                } else if ([alert isKindOfClass:[NSDictionary class]]) {
                    info[@"title"] = alert[@"title"] ?: @"";
                    info[@"subtitle"] = alert[@"subtitle"] ?: @"";
                    info[@"body"] = alert[@"body"] ?: @"";
                }

                if (aps[@"badge"]) {
                    info[@"badge"] = aps[@"badge"];
                }
            }

            // 保存完整 userInfo（如果可序列化）
            if ([NSJSONSerialization isValidJSONObject:userInfo]) {
                info[@"userInfo"] = userInfo;
            }

            writePendingNotificationAsync(info);
            NSLog(@"[TrollScriptHook] Remote notification (background) intercepted");
        } @catch (NSException *e) {
            NSLog(@"[TrollScriptHook] Error in didReceiveRemoteNotification: %@", e);
        }
    }

    %orig;
}

%end

// MARK: - Constructor

%ctor {
    @autoreleasepool {
        NSString *bundleID = getSafeBundleID();

        // 排除系统进程
        if ([bundleID hasPrefix:@"com.apple."] && ![bundleID isEqualToString:@"com.apple.springboard"]) {
            NSLog(@"[TrollScriptHook] Skipping system app: %@", bundleID);
            return;
        }

        NSLog(@"[TrollScriptHook] Initializing in app: %@", bundleID);

        // 确保目录存在
        ensureDirectoryExists();

        // 发送启动通知
        notify_post([kTrollScriptAppLaunchedName UTF8String]);

        // 写入启动事件
        NSDictionary *event = @{
            @"bundleID": bundleID,
            @"event": @"app_launched",
            @"timestamp": @([[NSDate date] timeIntervalSince1970]),
            @"processID": @(getpid())
        };
        writeEventAsync(event);

        // 延迟 hook 现有的 delegate（如果已经设置）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
            UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
            id<UNUserNotificationCenterDelegate> delegate = center.delegate;
            if (delegate) {
                hookDelegateClass([delegate class]);
                NSLog(@"[TrollScriptHook] Late-hooked existing delegate: %@", NSStringFromClass([delegate class]));
            }
        });

        NSLog(@"[TrollScriptHook] Initialization complete");
    }
}
