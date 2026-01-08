# TrollScriptHook

iOS 通知拦截 Hook - 纯 Objective-C Runtime 实现，不依赖 CydiaSubstrate 或 Theos，可直接通过 `insert_dylib` 注入。

## 功能特性

### 通知拦截

- **本地通知** - Hook `UNUserNotificationCenter.addNotificationRequest:withCompletionHandler:`
- **前台远程通知** - Hook delegate 的 `userNotificationCenter:willPresentNotification:withCompletionHandler:`
- **通知响应** - Hook delegate 的 `userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:`
- **远程通知注册** - Hook `UIApplication.registerForRemoteNotifications`

### 数据收集

拦截的通知包含以下信息：

| 字段 | 说明 |
|------|------|
| `bundleID` | 应用 Bundle ID |
| `identifier` | 通知标识符 |
| `title` | 通知标题 |
| `subtitle` | 通知副标题 |
| `body` | 通知正文 |
| `badge` | 角标数字 |
| `timestamp` | 时间戳 |
| `type` | 通知类型 (`local` / `remote_foreground` / `response`) |
| `userInfo` | 自定义数据 (JSON 兼容时) |
| `actionIdentifier` | 用户操作标识 (仅 response 类型) |

### 技术特点

- **纯 Runtime 实现** - 使用 `method_setImplementation` 和 `imp_implementationWithBlock`
- **无外部依赖** - 不依赖 Theos 或 CydiaSubstrate
- **双架构支持** - 同时支持 arm64 和 arm64e
- **线程安全** - 使用串行 GCD 队列处理文件写入
- **原子写入** - 使用 `NSDataWritingAtomic` 确保数据完整性
- **自动过滤** - 跳过系统应用 (除 SpringBoard 外)
- **延迟 Hook** - 支持 hook 已存在的 delegate

## 数据存储

### 文件路径

```
/var/mobile/Library/TrollScript/HookData/
├── pending_notifications.json  # 待处理通知队列 (最多 100 条)
└── latest_event.json           # 最新事件
```

### Darwin 通知

| 通知名称 | 触发时机 |
|----------|----------|
| `com.trollscript.hook.notification` | 新通知被拦截 |
| `com.trollscript.hook.app.launched` | 注入的 App 启动 |

## 构建

### 环境要求

- macOS
- Xcode Command Line Tools (`xcode-select --install`)
- iOS SDK

### 编译

```bash
# 添加执行权限
chmod +x build.sh

# 编译
./build.sh
```

编译脚本会自动：
1. 检测 iOS SDK 路径
2. 分别编译 arm64 和 arm64e 架构
3. 使用 `lipo` 合并为通用二进制
4. 使用 ad-hoc 签名

### 输出

```
build/TrollScriptHook.dylib
```

## 使用方式

使用 `insert_dylib` 或其他工具将 dylib 注入目标 App：

```bash
insert_dylib --strip-codesig --all-yes \
  build/TrollScriptHook.dylib \
  /path/to/App.app/App
```

## 数据格式示例

### 通知数据 (pending_notifications.json)

```json
[
  {
    "bundleID": "com.example.app",
    "identifier": "notification-123",
    "title": "新消息",
    "subtitle": "",
    "body": "你有一条新消息",
    "badge": 1,
    "timestamp": 1704672000,
    "type": "remote_foreground",
    "userInfo": {}
  }
]
```

### 事件数据 (latest_event.json)

```json
{
  "bundleID": "com.example.app",
  "event": "app_launched",
  "timestamp": 1704672000,
  "processID": 12345
}
```

## 注意事项

- 仅在越狱或 TrollStore 环境下可用
- 系统应用 (`com.apple.*`) 默认被跳过，SpringBoard 除外
- 非 JSON 兼容的 userInfo 会被忽略
- 待处理通知队列超过 100 条时，旧通知会被移除
- 最低支持 iOS 14.0

## License

MIT
