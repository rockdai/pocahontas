# pocahontas

<p align="center">
  <img src="assets/logo/pocahontas.png" width="160" alt="pocahontas — 白底黑色 Contrail One 大写 P Logo">
</p>

Terminal made for coding agents，首版同时支持 iPhone、iPad 和原生 macOS。

通过 SSH 连接开发机器，使用 Ghostty 渲染终端，以远端 tmux 会话承载持续运行的 coding agent。通过统一的连接库管理主机、SSH 身份和工作区，在用户开启同步后跨 Apple 设备共享。

当前已有三平台 M0 原型：Ghostty / Metal 终端、SSH 密码与加密 OpenSSH Ed25519 私钥认证、首次连接指纹确认、主机密钥变化阻断，以及中文输入、快捷键、粘贴和终端尺寸同步。

App 与终端统一使用固定浅色外观，不跟随系统深色模式，也不提供外观切换。终端使用白底、深色文字和适配浅色背景的 ANSI 配色，并向支持外观检测的远端程序报告浅色模式。

[浏览 iPhone / iPad 界面截图](docs/screenshots/ios-m0/README.md) · [浏览 Mac 界面截图](docs/screenshots/macos-m0/README.md)：连接配置、文件导入、主机指纹、终端、键盘、多行粘贴和错误提示，包含横屏与竖屏。

已加入三端共用的本地连接库、SSH 身份管理、CloudKit 配置同步与逐项选择的 iCloud Keychain 凭据存储。快速连接仍只使用一次性凭据；已保存连接可在离线时使用。同步实现包括持久 outbox、冲突审阅、删除标记和账号隔离。**当前开发 profile 尚未关联目标 iCloud container，真实跨设备同步仍待签名配置与真机验收**，详见 [iCloud 构建与验收](docs/icloud-setup.md)。

Mac 版提供原生窗口、独立并行连接、鼠标选区、⌘C / ⌘V 与中文输入；切换到其他 App 不会断开 SSH，关闭窗口或系统睡眠时断开。自动 tmux 工作区尚未实现，目前可在远端手动运行 tmux，返回 App 后重新连接并 attach。

[浏览连接库、SSH 身份与 iCloud 设置的三端截图](docs/screenshots/library/README.md)。

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

## 验证

iCloud 联调使用 `pocahontas-iCloud` 或 `pocahontas-macOS-iCloud` scheme（`CloudDebug`），两端需使用同一开发团队、container 和共享 Keychain group。普通 Mac Debug 不具备 Data Protection Keychain 凭据权限，因此可保存配置，连接时输入密码；正式签名构建才启用持久凭据。具体步骤见 [iCloud 构建说明](docs/icloud-setup.md)。

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

该脚本在随机 loopback 端口运行专用 fixture；每次新端点都验证首次信任，不清除已有主机指纹。本机原生单元测试通过，Mac XCUITest 启动自动化超时，本轮桌面截图改由 Computer Use 操作真实窗口保存；详见截图索引。

## 设计与集成记录

- [产品范围、终端架构与实施顺序](docs/architecture.md)
- [SSH 连接库与 iCloud 同步设计](docs/ssh-sync.md)
- [M0 实现与验证记录](docs/m0-integration.md)
- [依赖来源与许可证](THIRD_PARTY_NOTICES.md)

目标架构：SwiftUI 原生界面、共享 Swift Package、GhosttyKit + madeye passthru IO、SSH transport，以及 CloudKit 配置同步 + iCloud Keychain 凭据同步。
