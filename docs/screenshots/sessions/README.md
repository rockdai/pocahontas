# 多会话：iPhone / iPad / macOS

本目录包含 32 张实际运行截图：iPhone 12 张、iPad 12 张、原生 Mac 8 张，均为 XCTest 原始 PNG 附件，未合成或修改。移动端在系统深色模式下拍摄，App 与终端保持浅色。测试仅连接本机 loopback SSH fixture。

点击顶部 **＋** 新建会话，点击标签切换，点击 **×** 只关闭对应会话。相同主机可以重复打开；新建表单和未选中的标签不会断开已有 SSH 连接。Mac 保留独立多窗口，支持 **⌘T** 新会话、**⌘N** 新窗口和 **⌃Tab / ⌃⇧Tab** 切换标签。

每个窗口的 `TerminalWorkspace` 持有独立的 `TerminalController` 集合，每个控制器拥有自己的 SSHSession、Ghostty surface、指纹确认与输入状态。移除屏幕上的 SwiftUI view 不销毁 surface，隐藏会话继续解析收到的数据；只有当前 surface 需要绘制。切换时丢弃未提交的 IME 内容和一次性 Ctrl / Alt 状态，避免串到下一会话。

活动会话仅在当前 App 进程中保留，不写入 iCloud。iOS 进入后台、Mac 睡眠或连接库账号改变时，结束对应窗口的连接；关闭 Mac 窗口只结束该窗口内的会话。这里没有新增自动重连或本地终端回放，持久任务仍需远端 tmux。

## 验证

- iPhone、iPad 各 11 项 App 测试及 1 条多会话 UI 流程通过。
- Mac 9 项原生测试及 1 条多会话 UI 流程通过，包含新窗口和关闭窗口隔离。
- 集成测试通过真实 SSH 往返读取 Ghostty 的输出，确认两路内容互不混入、隐藏会话持续接收输出、关闭一个会话后另一路继续收发、认证失败隔离、取消尚未开始的连接、账号变化取消、IME / 修饰键清理。
- 连接库回归覆盖同一已保存主机连续打开两次，仍读取真实 Keychain 密码；不会替换原来的会话。

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
