//
//  Tweak.x
//  TrollScriptHook
//
//  通知拦截 Hook - 注入到目标 App 后拦截通知并转发给 TrollScript
//

#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import <notify.h>

// MARK: - Constants

static NSString * const kTrollScriptNotificationName = @"com.trollscript.hook.notification";
static NSString * const kTrollScriptAppLaunchedName = @"com.trollscript.hook.app.launched";
static NSString * const kTrollScriptSharedPath = @"/var/mobile/Library/TrollScript/HookData";

// MARK: - Helper Functions

static void writePendingNotification(NSDictionary *info) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dirPath = kTrollScriptSharedPath;
    
    // 创建目录
    if (![fm fileExistsAtPath:dirPath]) {
        [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    // 读取现有数据
    NSString *filePath = [dirPath stringByAppendingPathComponent:@"pending_notifications.json"];
    NSMutableArray *pending = [NSMutableArray array];
    
    if ([fm fileExistsAtPath:filePath]) {
        NSData *data = [NSData dataWithContentsOfFile:filePath];
        if (data) {
            NSArray *existing = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (existing) {
                [pending addObjectsFromArray:existing];
            }
        }
    }
    
    // 添加新通知
    [pending addObject:info];
    
    // 限制最大数量
    while (pending.count > 100) {
        [pending removeObjectAtIndex:0];
    }
    
    // 写入文件
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:pending options:0 error:nil];
    [jsonData writeToFile:filePath atomically:YES];
}

// MARK: - UNUserNotificationCenter Hook

%hook UNUserNotificationCenter

// Hook 添加本地通知请求
- (void)addNotificationRequest:(UNNotificationRequest *)request 
         withCompletionHandler:(void (^)(NSError *))completionHandler {
    
    @try {
        // 获取通知内容
        UNNotificationContent *content = request.content;
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        
        // 构建通知信息
        NSDictionary *info = @{
            @"bundleID": bundleID,
            @"identifier": request.identifier ?: @"",
            @"title": content.title ?: @"",
            @"subtitle": content.subtitle ?: @"",
            @"body": content.body ?: @"",
            @"badge": content.badge ?: @0,
            @"timestamp": @([[NSDate date] timeIntervalSince1970]),
            @"type": @"local"
        };
        
        // 写入共享目录
        writePendingNotification(info);
        
        // 发送 Darwin 通知给 TrollScript
        notify_post([kTrollScriptNotificationName UTF8String]);
        
        NSLog(@"[TrollScriptHook] Local notification intercepted: %@", content.title);
    } @catch (NSException *e) {
        NSLog(@"[TrollScriptHook] Error intercepting notification: %@", e);
    }
    
    // 调用原始方法
    %orig;
}

%end

// MARK: - UNUserNotificationCenterDelegate Hook (远程通知)

%hook UNUserNotificationCenterDelegate

// Hook 前台收到通知
- (void)userNotificationCenter:(UNUserNotificationCenter *)center 
       willPresentNotification:(UNNotification *)notification 
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    
    @try {
        UNNotificationContent *content = notification.request.content;
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        
        NSDictionary *info = @{
            @"bundleID": bundleID,
            @"identifier": notification.request.identifier ?: @"",
            @"title": content.title ?: @"",
            @"subtitle": content.subtitle ?: @"",
            @"body": content.body ?: @"",
            @"badge": content.badge ?: @0,
            @"timestamp": @([[NSDate date] timeIntervalSince1970]),
            @"type": @"remote"
        };
        
        writePendingNotification(info);
        notify_post([kTrollScriptNotificationName UTF8String]);
        
        NSLog(@"[TrollScriptHook] Remote notification intercepted: %@", content.title);
    } @catch (NSException *e) {
        NSLog(@"[TrollScriptHook] Error: %@", e);
    }
    
    %orig;
}

// Hook 用户响应通知
- (void)userNotificationCenter:(UNUserNotificationCenter *)center 
didReceiveNotificationResponse:(UNNotificationResponse *)response 
         withCompletionHandler:(void (^)(void))completionHandler {
    
    @try {
        UNNotificationContent *content = response.notification.request.content;
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        
        NSDictionary *info = @{
            @"bundleID": bundleID,
            @"identifier": response.notification.request.identifier ?: @"",
            @"title": content.title ?: @"",
            @"subtitle": content.subtitle ?: @"",
            @"body": content.body ?: @"",
            @"actionIdentifier": response.actionIdentifier ?: @"",
            @"timestamp": @([[NSDate date] timeIntervalSince1970]),
            @"type": @"response"
        };
        
        writePendingNotification(info);
        notify_post([kTrollScriptNotificationName UTF8String]);
        
        NSLog(@"[TrollScriptHook] Notification response intercepted");
    } @catch (NSException *e) {
        NSLog(@"[TrollScriptHook] Error: %@", e);
    }
    
    %orig;
}

%end

// MARK: - Constructor

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSLog(@"[TrollScriptHook] Loaded in app: %@", bundleID);
        
        // 通知 TrollScript App 已启动
        notify_post([kTrollScriptAppLaunchedName UTF8String]);
        
        // 写入启动事件
        NSString *dirPath = kTrollScriptSharedPath;
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dirPath]) {
            [fm createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:nil];
        }
        
        NSDictionary *event = @{
            @"bundleID": bundleID ?: @"unknown",
            @"event": @"app_launched",
            @"timestamp": @([[NSDate date] timeIntervalSince1970])
        };
        
        NSString *eventPath = [dirPath stringByAppendingPathComponent:@"latest_event.json"];
        NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
        [data writeToFile:eventPath atomically:YES];
    }
}
