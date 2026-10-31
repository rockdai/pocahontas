# pocahontas

<p align="center">
  <img src="assets/logo/pocahontas.png" width="160" alt="pocahontas — 白底黑色 Contrail One 大写 P Logo">
</p>

Terminal made for coding agents，首先支持 iOS / iPadOS，后续支持原生 macOS。

通过 SSH 连接开发机器，使用 Ghostty 渲染终端，以远端 tmux 会话承载持续运行的 coding agent。通过统一的连接库管理主机、SSH 身份和工作区，在用户开启同步后跨 Apple 设备共享。

当前已有 M0 iOS 原型：Ghostty / Metal 终端、SSH 密码与加密 OpenSSH Ed25519 私钥认证、首次连接指纹确认、主机密钥变化阻断，以及中文输入、快捷键、粘贴和终端尺寸同步。

App 与终端统一使用固定浅色外观，不跟随系统深色模式，也不提供外观切换。终端使用白底、深色文字和适配浅色背景的 ANSI 配色，并向支持外观检测的远端程序报告浅色模式。

[浏览 iPhone / iPad 界面截图](docs/screenshots/ios-m0/README.md)：连接配置、文件导入、主机指纹、终端、键盘、多行粘贴和错误提示，包含横屏与竖屏。

原型仅保存本机最近一次连接的地址、端口、用户名和已确认的服务器指纹；密码和私钥只保留在当前连接内存中。多主机连接库、身份持久化、自动 tmux 工作区、iCloud 同步与 macOS UI 尚未实现。当前可在远端手动运行 tmux，返回 App 后重新连接并 attach。

## 构建

已验证工具链：Xcode 26.6、Swift 6.3.3、Homebrew `zig@0.15` 0.15.2。最低系统版本 iOS 17；模拟器构建为 arm64。

```sh
brew install zig@0.15 xcodegen jq
git submodule update --init
scripts/build-ghostty.sh
scripts/generate-project.sh
open pocahontas.xcodeproj
```

在 Xcode 选择 `pocahontas` scheme 和模拟器运行。模拟器使用专用 ad-hoc 签名 entitlement 访问真实 Keychain，无需设置开发团队。真机需在 Signing & Capabilities 中选择自己的团队。不要用 `CODE_SIGNING_ALLOWED=NO` 运行 Keychain 集成测试。

`project.yml` 是工程配置源；重新生成工程使用 `scripts/generate-project.sh`，该脚本同时将已提交的 Swift package 版本锁复制到 Xcode。Ghostty 构建产物位于 `Frameworks/`，不入库；构建脚本只修改项目内的 Zig 缓存。

## 验证

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

## 设计与集成记录

- [产品范围、终端架构与实施顺序](docs/architecture.md)
- [SSH 连接库与 iCloud 同步设计](docs/ssh-sync.md)
- [M0 实现与验证记录](docs/m0-integration.md)
- [依赖来源与许可证](THIRD_PARTY_NOTICES.md)

目标架构：SwiftUI 原生界面、共享 Swift Package、GhosttyKit + madeye passthru IO、SSH transport，以及 CloudKit 配置同步 + iCloud Keychain 凭据同步。
