# ADR-0054: Termux-owned workspace terminal sessions

Status: accepted

Android 工作区终端需要在页面销毁后保留 PTY、TUI 屏幕、光标和滚动历史，且可由用户选择在应用任务被划掉后继续运行。原先由 Flutter 页面持有 `flutter_pty` 与 `xterm` 的方案只能覆盖页面级生命周期，无法满足这个会话所有权边界。本决策取代 ADR-0032 中“退出页面即结束会话”的部分；“交互终端必须使用 PTY，而不是一次性 exec”仍然成立。

## Decision

- 完整引入 Termux 固定提交 `30ebb2dee381d292ade0f2868cfde0f9f20b89fe` 的 `terminal-emulator`、`terminal-view` 与 `termux-shared` library 模块。复用 `TerminalSession`、`TerminalEmulator`、`TerminalView`、`TermuxSession`、`ExecutionCommand`、`TermuxShellManager` 以及 Termux 的基础 session/view client。
- 不嵌入原版 `TermuxService`。它与 TermuxApplication、bootstrap、Activity、插件执行协议和 `$PREFIX` 强耦合；Cuplivo 只保留一个薄 Service，将既有 proot launch spec 交给自定义 `IShellEnvironment`，负责工作区映射、Flutter 通道与 Android 前台保活。
- Service 是终端会话的唯一所有者。每个工作区最多一个会话，不同工作区可以并行。PlatformView 只附着或分离 Termux `TerminalView`，不拥有 PTY；重新附着同一个会话时直接恢复原生屏幕状态。
- 会话分为三层生命周期：页面附着；离开页面后仍存在的应用内会话；带 `specialUse` 前台通知、CPU WakeLock 与高性能 Wi-Fi Lock 的持久保活会话。普通应用内会话在任务被划掉时结束；持久会话只保证当前应用进程内跨任务存活，强制停止、系统杀进程和设备重启仍会结束。
- 三个工作区设置写入同一份工作区元数据：退出后保留是父开关，持久保活与应用启动时打开 Linux 沙箱是子开关。父开关关闭时先结束会话，再原子清空三个值；非法或旧备份组合在模型边界归一化。
- 开启持久保活前请求通知权限；权限被拒绝时保持该开关关闭并向用户说明原因，避免持久会话在没有可见前台通知的情况下静默运行。
- 自动启动发生在首帧已取得本地化通知文案，且工作区元数据与 SAF 挂载初始化完成之后。按工作区顺序启动登录 Shell；失败记录上下文但保留用户选择。
- 删除工作区、改变工作区路径或 SAF 绑定、重装 rootfs、清理沙箱及覆盖恢复前，必须先等待相关会话结束。停止失败即取消破坏性操作。
- 终端模块的上游 NOTICE、完整许可证、固定提交与接入修改说明一并保留。Cuplivo 的集成代码继续随项目以 AGPL-3.0 发布。

## Consequences

- Flutter Engine 或终端页面重建不再丢失 PTY 与 TUI 状态；页面也不再复制终端模拟器行为。
- Termux 三个库的 Android 源码和 JNI 成为仓库内固定依赖，升级必须作为显式的上游提交变更审查其 API、许可证和 native ABI。
- 前台保活会增加电量消耗并受通知权限、Android 版本及厂商后台策略影响，所以保持默认关闭并向用户显示独立低重要度通知。
- 当前边界不包含同一工作区多会话、终端背景美化、设备开机自启、iOS 或桌面终端持久化。

## Considered options

- **继续让 Flutter 页面持有 `flutter_pty` 和 `xterm`**：无法跨 Flutter Engine 生命周期保留 PTY 与准确屏幕状态，拒绝。
- **复制 TermuxService**：能复用更多应用层代码，但会同时引入 Termux bootstrap、Activity 与插件协议，远超 Cuplivo 工作区会话边界，拒绝。
- **完全自研 Android PTY、模拟器和视图**：重复实现选区、键盘、TUI、滚动缓冲及 JNI，维护风险最高，拒绝。
