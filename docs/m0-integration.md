# M0 集成记录

日期：2026-10-26。这个切片验证 iOS 终端与真实 SSH 协议的闭环；产品范围仍以 [架构设计](architecture.md) 为准。

## 已实现

- iOS / iPadOS 17+ SwiftUI App 和共享 `PocahontasKit` Swift Package，Swift 6 模式。
- Ghostty 完整 surface / Metal 集成，madeye passthru IO，字节直通与终端自动应答。
- SSH 密码、未加密 / 加密 OpenSSH Ed25519 私钥认证。密钥在后台任务解析，错误 passphrase 明确失败，无认证降级。
- 首次连接显示 SHA256 指纹，用户确认后写本机 Keychain；已信任服务器的 key 变化直接阻断。
- 等待 PTY 与 shell 两个成功回复后才开放输入，认证被拒绝立即失败，不等连接超时。
- 中文组合输入、Ctrl / Alt / Esc / Tab / 方向键、bracketed paste、多行粘贴预览、resize 和本地 history 滚动按钮。
- SSH 输出保留原始字节；下行通过 ACK 配合 channel autoRead 控制背压，上行有 1 MiB 待写预算。超限显式断开，不静默丢字节。
- App 进入后台主动断开、暂停绘制并遮盖私密界面；旧连接回调不能进入新 surface。

## 锁定的依赖

| 依赖 | 集成版本 | 使用范围 |
| --- | --- | --- |
| madeye/ghostty | `7fb9e90363a431d15a67a22ff661e33c1be59060` | 完整 terminal / Metal / passthru。没有加入 baxian 的自动应答抑制 patch。 |
| Citadel | `0.12.1` / `ae8562f895de06ccb86fdb1cbb65fd99c8976e12` | OpenSSH Ed25519 私钥解析与 passphrase 解密。 |
| Wellz26/swift-nio-ssh | `0.3.4` | Citadel 依赖的 SwiftNIO SSH fork；实际 transport 直接使用其 NIOSSH API。 |
| SwiftNIO / Swift Crypto 等 | `Packages/PocahontasKit/Package.resolved` | 网络 event loop 与密码学依赖。 |

与初始候选相比，NIOSSH 选用 Citadel 对应的 fork，以避免同时链接两套名称相同的 NIOSSH 模块。后续升级须同时复测 Citadel 的 key 解析与 SSH 协商，不把 fork 等同于 Apple upstream 的版本号。当前 UI 仅开放已验证的 Ed25519；不因依赖包含其他算法就宣称支持 RSA / MFA。

Ghostty 构建使用 Xcode 26.6（17F113）、Zig 0.15.2，`ReleaseFast`、`sentry=false`；对项目专属 Zig global cache 中的指定 libxev 版本应用 Darwin mach-port 修正。没有修改系统 Zig 安装、其他仓库或共享缓存。三套 XCFramework 切片的架构和 Mach-O platform 均经脚本验证。

## 测试覆盖

本轮验证结果（2026-10-26）：

| 验证 | 结果 |
| --- | --- |
| 共享 package 与真实 loopback SSH | 11 项通过，0 失败。 |
| iOS 单元测试 | 3 项通过，0 失败。 |
| iOS UI 端到端测试 | 1 项通过，0 失败；iPhone 17 Pro / iOS 26.5 模拟器。 |
| 界面截图回放 | iPhone / iPad 两条完整流程通过，生成 46 张原始截图；导出时检查横竖屏方向。 |
| iOS 设备目标编译与链接 | 通过；未签名构建，不代表真机运行验证。 |
| Ghostty XCFramework | iOS arm64、模拟器 arm64、macOS arm64 / x86_64 切片验证通过。 |

共享 package 测试覆盖连接参数、OpenSSH key 与公钥匹配、错误 passphrase、截断 key、host trust 分支，以及 PTY / shell 成功确认顺序。真实 loopback SSH 测试覆盖密码和加密 Ed25519 认证、非 UTF-8 字节往返、远端 resize、用户拒绝信任、host key 变化与错误密码快速失败。

iOS 测试直接调用实际 Ghostty surface 验证光标位置自动应答、Ctrl-C、中文提交、bracketed paste 和 resize；UI 测试通过真实 Keychain 确认主机身份并连接 fixture，再验证错误密码失败。截图人工检查终端显示与中文排版。

[界面截图索引](screenshots/ios-m0/README.md) 覆盖连接配置、文件导入、指纹确认、终端与键盘、多行粘贴、认证失败和后台断开等状态。可用 `scripts/capture-screenshots.sh` 重新生成。

测试 fixture 只是 loopback SSH echo 服务，不运行本机 shell，也不代表已完成真实 coding agent TUI 的兼容性验收。测试密钥仅用于 fixture，passphrase 是公开测试值。

## 尚待完成

| 项目 | 当前边界 |
| --- | --- |
| 真机与硬件键盘 | 本机未连接 iOS 真机；IME 与 key encoding 已有模拟器测试，真实键盘 / 手势和长时间功耗需真机验证。 |
| 长输出压力 | 有明确队列上限与流控，但尚未完成长时间 agent 流式输出和内存曲线测量。 |
| 会话恢复 | 连接关闭后不自动重放输入；用户可重新连接并手动 attach 远端 tmux。工作区管理、自动重连和多会话是 M1。 |
| 主机与身份管理 | 只有 quick connect；最近地址 / 用户名存本机 UserDefaults，host trust 存本机 Keychain。完整数据库与持久身份尚未引入。 |
| 复制与终端交互 | 当前完成输入、粘贴和基本滚动；文本选择复制、完整外接键盘映射、主题字号设置留在 M1。 |
| iCloud | 尚未创建 CloudKit container、共享 Keychain group 或同步 UI；M2 按同步设计落实，需正式开发团队签名。 |
| macOS | 引擎产物包含 macOS；共享 package 已在 macOS 测试，尚无 macOS App。 |

下一步以 M1 的主机 / SSH 身份持久化和 tmux 工作区为主，同时继续真机验证；随后接入 M2 的双通道同步。
