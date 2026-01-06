# TrollScriptHook

通知拦截 Tweak，注入到目标 App 后拦截通知并转发给 TrollScript。

## 构建

需要安装 [Theos](https://theos.dev/docs/installation)：

```bash
# 设置 THEOS 环境变量
export THEOS=~/theos

# 编译
cd TrollScriptHook
make package
```

## 输出

编译后生成 `.deb` 包，从中提取 `TrollScriptHook.dylib`：

```
.theos/_/Library/MobileSubstrate/DynamicLibraries/TrollScriptHook.dylib
```

## 功能

- Hook `UNUserNotificationCenter` 拦截本地通知
- Hook `UNUserNotificationCenterDelegate` 拦截远程通知
- 通过 Darwin Notification 通知 TrollScript
- 数据写入 `/var/mobile/Library/TrollScript/HookData/`

## 手动编译 (无 Theos)

如果没有 Theos，可以使用 Xcode 创建动态库项目，参考 `Tweak.x` 中的 Hook 逻辑。
