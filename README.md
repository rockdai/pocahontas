# Pocahontas

<p align="center">
  <img src="assets/logo/pocahontas.png" width="160" alt="Pocahontas — 白底黑色 Contrail One 大写 P Logo">
</p>

Terminal made for coding agents，首版同时支持 iPhone、iPad 和原生 macOS。

[下载 Mac 测试包（Apple Silicon）](https://github.com/rockdai/pocahontas/raw/refs/heads/main/downloads/Pocahontas-AppleSilicon.zip) · [安装说明与 SHA-256 校验](downloads/README.md)。包内应用名为 **Pocahontas.app**，无需 Xcode；这是尚未公证的本地功能测试版。

通过 SSH 连接开发机器，使用 Ghostty 渲染终端，以远端 tmux 会话承载持续运行的 coding agent。通过统一的连接库管理主机、SSH 身份和工作区，目标是通过 Pocahontas 账号跨 Apple、Android 与鸿蒙设备共享；Android 与鸿蒙客户端尚在规划中。

当前已有三平台 M0 原型：Ghostty / Metal 终端、SSH 密码与加密 OpenSSH Ed25519 私钥认证、首次连接指纹确认、主机密钥变化阻断，以及中文输入、快捷键、粘贴和终端尺寸同步。

App 与终端统一使用固定浅色外观，不跟随系统深色模式，也不提供外观切换。终端使用白底、深色文字和适配浅色背景的 ANSI 配色，并向支持外观检测的远端程序报告浅色模式。

[浏览 iPhone / iPad 界面截图](docs/screenshots/ios-m0/README.md) · [浏览 Mac 界面截图](docs/screenshots/macos-m0/README.md)：连接配置、文件导入、主机指纹、终端、键盘、多行粘贴和错误提示，包含横屏与竖屏。

已加入三端共用的本地连接库与 SSH 身份管理。快速连接仅在当前 tab 存续期间将凭据保留在内存中，以便重连，不写入持久存储；已保存连接可在离线时使用。本地逻辑包括持久 outbox、冲突审阅、删除标记和账号隔离。

**已实现 Pocahontas server 与三端账号加密同步，移除 iCloud。** Node.js + 阿里云函数计算 + PostgreSQL，只有三张基础表，不使用显式多语句事务和外键。注册验证邮箱；同一个密码完成登录与本机解密，改密码保留资料，邮箱重置需确认清空云端资料。云端服务已部署，三端默认接入 `https://pocahontas-api.rockdai.com`；已通过本地双客户端与真实 PostgreSQL 联调，真实邮件和真机跨网络验收仍待执行。[运行、部署与 App 配置](server/README.md#运行方式)。不做旧版本兼容或数据迁移。

iPhone、iPad 和 Mac 都支持多个并行 SSH 会话：点击顶部 **＋** 新建，点击标签切换，点击标签的 **×** 单独关闭。同一台主机也可打开多个独立会话；切换标签或填写新连接时，其他连接继续接收输出。每个会话保留独立的终端内容、认证状态和输入。

Mac 还支持多个原生窗口：**⌘T** 新会话、**⌘N** 新窗口、**⌃Tab / ⌃⇧Tab** 切换会话；关闭窗口只关闭该窗口内的会话。顶部只保留与系统窗口按钮并排的会话栏，状态显示在 tab 内，完整连接地址可通过悬停查看；没有独立标题工具栏、复制粘贴按钮或底部提示栏。窗口使用系统原生的较小圆角。鼠标选区、⌘C / ⌘V 与中文输入继续可用，切换到其他 App 不会断开 SSH。iPhone/iPad 同样移除重复的终端标题与状态行，保留底部终端快捷键，并将触屏粘贴入口移到该处。

切换 tab、重新激活 Mac 窗口或返回 iOS App 时，会检测当前会话的 SSH 连接；静默失联在 5 秒内判定，并尝试重连。健康连接保持原有 shell。iOS 进入后台或 Mac 睡眠时仍会主动断开 SSH，返回后按激活的会话恢复，其他会话等切换时再恢复。重连保留原终端缓冲区，失败时可点击 **Reconnect**；新连接的服务器输出仍可能改变终端内容。认证或主机信任失败需要重新发起连接；正常退出远端 shell 后只允许手动重连。关闭 tab/窗口、连接库账号变化会清除重连凭据。自动 tmux 工作区尚未实现，重连会打开新的远端 shell；持续运行的任务需在远端 tmux 中运行并手动 attach。

[浏览多会话截图与验证记录](docs/screenshots/sessions/README.md) · [浏览连接库与 SSH 身份的历史三端截图（含旧 iCloud UI）](docs/screenshots/library/README.md)。

## 构建

已验证工具链：Xcode 26.6、Swift 6.3.3、Homebrew `zig@0.15` 0.15.2。最低系统版本 iOS / iPadOS 17、macOS 14；模拟器构建为 arm64。

```sh
brew install zig@0.15 xcodegen jq
git submodule update --init
scripts/build-ghostty.sh
scripts/generate-project.sh
open pocahontas.xcodeproj
```

在 Xcode 选择 `pocahontas` scheme 运行 iPhone / iPad，选择 `pocahontas-macOS` scheme 和 My Mac 运行原生 Mac App。Mac Debug 使用本地 ad-hoc 签名；发布构建需选择开发团队及正式签名。Mac 主机指纹保存在本机 login Keychain（仅本机信任，不同步）；正式签名保证应用身份在升级后保持稳定。模拟器使用专用 ad-hoc 签名 entitlement 访问真实 Keychain，无需设置开发团队。真机需在 Signing & Capabilities 中选择自己的团队。不要用 `CODE_SIGNING_ALLOWED=NO` 运行 Keychain 集成测试。

`project.yml` 是工程配置源；重新生成工程使用 `scripts/generate-project.sh`，该脚本同时将已提交的 Swift package 版本锁复制到 Xcode。Ghostty 构建产物位于 `Frameworks/`，不入库；构建脚本只修改项目内的 Zig 缓存。

三端应用图标使用 `assets/logo` 中的白底黑色 P。执行 `swift scripts/generate-logo.swift` 可同时重建 Logo 和共享的 AppIcon 资源。

## 验证

账号服务和客户端验证入口如下，需要 Node.js 20+ 与 PostgreSQL 的 `initdb` / `pg_ctl`。测试自动建立并销毁临时数据库，邮件留在测试内存中，不访问真实账号。

```sh
npm ci --prefix server
npm test --prefix server
scripts/test-account.sh
scripts/capture-account-screenshots.sh
```

账号截图与平台验收情况见 [Account & Sync](docs/screenshots/account/README.md)。默认连接正式服务，显式将 `POCAHONTAS_SERVER_URL` 设为空时使用本地模式；配置方法见 [server](server/README.md#app-配置)。Mac 普通 Debug 使用本机 login Keychain 保存凭据和登录材料，不需要 iCloud entitlement。

共享逻辑测试：

```sh
cd Packages/PocahontasKit
swift test -j 4
```

包含真实 SSH 握手的本机集成测试：

```sh
python3 -m venv .build/test-venv
.build/test-venv/bin/pip install -r scripts/requirements-test.txt
scripts/test-ssh.sh
```

脚本仅在 `127.0.0.1:62223` 启动测试 SSH 服务，退出时关闭；使用生成的测试身份，不运行本机 shell。直接 `swift test` 会跳过这些网络集成测试。

iOS 单元 / UI 测试需要先在另一个终端启动 fixture，再执行 Xcode scheme 的 Test。也可使用：

```sh
.build/test-venv/bin/python scripts/ssh-fixture.py --state-dir .build/ssh-fixture
# 另一个终端；SIMULATOR_ID 取自 xcrun simctl list devices available
xcodebuild -project pocahontas.xcodeproj -scheme pocahontas \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -parallel-testing-enabled NO -disableAutomaticPackageResolution test
```

Mac 原生终端、Keychain 与 UI 测试入口（UI 自动化可用时导出 16 张基础截图）：

```sh
scripts/test-macos.sh
```

该脚本在随机 loopback 端口运行专用 fixture；每次新端点都验证首次信任，不清除已有主机指纹。M0 阶段 Mac XCUITest 曾发生自动化启动超时，历史截图使用实际窗口操作。本轮多会话的 Mac XCTest 与 XCUITest 已通过，可用 `scripts/test-session-macos.sh` 重跑并导出多会话截图。

## 设计与集成记录

- [产品范围、终端架构与实施顺序](docs/architecture.md)
- [Pocahontas 统一后台：账号与密文存储](server/README.md)
- [多端连接库与凭据](docs/ssh-sync.md)
- [M0 实现与验证记录](docs/m0-integration.md)
- [依赖来源与许可证](THIRD_PARTY_NOTICES.md)

目标架构：Apple 原生界面与共享 Swift Package、GhosttyKit + madeye passthru IO、SSH 直连，以及 Node.js / 阿里云函数计算 / PostgreSQL 统一后台。连接库在客户端加密后上传，平台安全存储仅用于本机凭据和解锁密钥。
