# 多会话：iPhone / iPad / macOS

本目录保留初版多会话的 32 张实际运行截图：iPhone 12 张、iPad 12 张、原生 Mac 8 张，均为 XCTest 原始 PNG 附件，未合成或修改。初版移动端截图在系统深色模式下拍摄，App 与终端保持浅色。测试仅连接本机 loopback SSH fixture。

点击顶部 **＋** 新建会话，点击标签切换，点击 **×** 只关闭对应会话。相同主机可以重复打开；新建表单和未选中的标签不会断开已有 SSH 连接。Mac 保留独立多窗口，支持 **⌘T** 新会话、**⌘N** 新窗口和 **⌃Tab / ⌃⇧Tab** 切换标签。

每个窗口的 `TerminalWorkspace` 持有独立的 `TerminalController` 集合，每个控制器拥有自己的 SSHSession、Ghostty surface、指纹确认与输入状态。移除屏幕上的 SwiftUI view 不销毁 surface，隐藏会话继续解析收到的数据；只有当前 surface 需要绘制。切换时丢弃未提交的 IME 内容和一次性 Ctrl / Alt 状态，避免串到下一会话。

活动会话仅在当前 App 进程中保留，不写入 iCloud。iOS 进入后台或 Mac 睡眠时结束对应窗口的连接，返回前台、激活窗口或切换 tab 后恢复当前会话。健康连接只做存活检测；静默失联通过 5 秒限时的空 SSH 通道探测发现，不向终端输入字符，也不执行命令。关闭 tab/窗口或连接库账号改变会清除重连凭据，认证与信任失败不会反复自动尝试。重连保留终端缓冲区，但建立的是新 shell，持久任务仍需远端 tmux 并手动 attach。

2026-11-02 体验优化：Mac 使用系统原生标题栏窗口的小圆角，将会话与状态集中在顶部，移除独立标题工具栏和底部提示栏。iPhone / iPad 同步移除重复的终端标题与状态行，将粘贴入口移至终端快捷键区。Mac 窗口圆角随系统样式决定，参见 [Apple 的 AppKit 窗口设计说明](https://developer.apple.com/videos/play/wwdc2025/310/)。

本轮界面截图：[iPhone](../experience/iphone.png) · [iPad](../experience/ipad.png)。这两张来自本轮通过的 XCTest 原始附件。下方完整图库保留为历史记录；本轮 Mac 截图受无关系统对话框遮挡，未替换历史图片。

## 验证

- iPhone、iPad 各 15 项 App 测试及 1 条多会话 UI 流程通过，覆盖横竖屏、独立关闭和返回前台自动重连。
- Mac 13 项原生测试及 2 条 UI 流程通过，覆盖顶栏布局、复制粘贴、独立窗口与窗口激活重连。
- 集成测试通过真实 SSH 往返读取 Ghostty 的输出，确认两路内容互不混入、隐藏会话持续接收输出、关闭一个会话后另一路继续收发、认证失败隔离、取消尚未开始的连接、账号变化取消、IME / 修饰键清理。
- 连接库回归覆盖同一已保存主机连续打开两次，仍读取真实 Keychain 密码；不会替换原来的会话。
- 新增真实 SSH 断线与静默丢包测试，验证健康连接不被替换、通道数限制不误判为断网、后台会话不抢先重连、账号变化清除凭据，以及重连期间关闭 tab 不会创建孤立连接。

```sh
scripts/capture-session-screenshots.sh
scripts/test-session-macos.sh
```

第一条脚本创建并清理两个专用模拟器，在 `127.0.0.1:62226` 启动测试服务，导出移动端截图。第二条脚本在随机 loopback 端口启动测试服务，导出 Mac 截图。依赖与构建准备见项目 README。连接库回归仍包含在 `scripts/capture-library-screenshots.sh` 中。

## iPhone 与 iPad

| 场景 | iPhone | iPad |
| --- | --- | --- |
| 新会话入口 | ![新会话入口 iPhone](iphone/01-new-session.png) | ![新会话入口 iPad](ipad/01-new-session.png) |
| 第一个连接 | ![第一个连接 iPhone](iphone/02-first-session.png) | ![第一个连接 iPad](ipad/02-first-session.png) |
| 第一个连接 · 横屏 | ![第一个连接 · 横屏 iPhone](iphone/03-first-session-landscape.png) | ![第一个连接 · 横屏 iPad](ipad/03-first-session-landscape.png) |
| 已有连接时新建 | ![已有连接时新建 iPhone](iphone/04-add-while-connected.png) | ![已有连接时新建 iPad](ipad/04-add-while-connected.png) |
| 已有连接时新建 · 横屏 | ![已有连接时新建 · 横屏 iPhone](iphone/05-add-while-connected-landscape.png) | ![已有连接时新建 · 横屏 iPad](ipad/05-add-while-connected-landscape.png) |
| 两个并行连接 | ![两个并行连接 iPhone](iphone/06-two-sessions.png) | ![两个并行连接 iPad](ipad/06-two-sessions.png) |
| 两个并行连接 · 横屏 | ![两个并行连接 · 横屏 iPhone](iphone/07-two-sessions-landscape.png) | ![两个并行连接 · 横屏 iPad](ipad/07-two-sessions-landscape.png) |
| 切回第一个会话 | ![切回第一个会话 iPhone](iphone/08-switch-to-first.png) | ![切回第一个会话 iPad](ipad/08-switch-to-first.png) |
| 切回第一个会话 · 横屏 | ![切回第一个会话 · 横屏 iPhone](iphone/09-switch-to-first-landscape.png) | ![切回第一个会话 · 横屏 iPad](ipad/09-switch-to-first-landscape.png) |
| 关闭其他会话后继续连接 | ![关闭其他会话后继续连接 iPhone](iphone/10-close-other-session.png) | ![关闭其他会话后继续连接 iPad](ipad/10-close-other-session.png) |
| 单个会话认证失败 | ![单个会话认证失败 iPhone](iphone/11-independent-failure.png) | ![单个会话认证失败 iPad](ipad/11-independent-failure.png) |
| 单个会话认证失败 · 横屏 | ![单个会话认证失败 · 横屏 iPhone](iphone/12-independent-failure-landscape.png) | ![单个会话认证失败 · 横屏 iPad](ipad/12-independent-failure-landscape.png) |

## macOS

### 新会话入口

![新会话入口 Mac](mac/01-new-session.png)

### 第一个连接

![第一个连接 Mac](mac/02-first-session.png)

### 已有连接时新建

![已有连接时新建 Mac](mac/04-add-while-connected.png)

### 两个并行连接

![两个并行连接 Mac](mac/06-two-sessions.png)

### 切回第一个会话

![切回第一个会话 Mac](mac/08-switch-to-first.png)

### 关闭其他会话后继续连接

![关闭其他会话后继续连接 Mac](mac/10-close-other-session.png)

### 单个会话认证失败

![单个会话认证失败 Mac](mac/11-independent-failure.png)

### 独立的新窗口

![独立的新窗口 Mac](mac/13-independent-window.png)
