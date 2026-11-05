# Pocahontas Mac 测试包

[下载 Pocahontas-0.1.0-macos-arm64.zip](https://github.com/rockdai/pocahontas/releases/download/macos-0.1.0-3809ff693969/Pocahontas-0.1.0-macos-arm64.zip) · [下载 SHA-256 校验文件](https://github.com/rockdai/pocahontas/releases/download/macos-0.1.0-3809ff693969/Pocahontas-0.1.0-macos-arm64.zip.sha256)

解压后将 **Pocahontas.app** 拖入“应用程序”，即可在另一台 MacBook 上测试，无需安装 Xcode。更新已有安装时，先退出旧版 App，再替换“应用程序”中的 Pocahontas.app。

- 适用于 Apple 芯片（M1 或更新），项目最低系统 macOS 14；Intel Mac 不适用，最低系统版本仍待实机验收。
- 这是 Release 测试构建，已使用 Developer ID 签名，通过 Apple 公证及 Gatekeeper 校验。
- 支持 SSH 密码 / Ed25519 私钥连接、并行会话、多窗口、本地连接配置及 Pocahontas 账号加密同步。
- **⌘T** 新会话，**⌃Tab / ⌃⇧Tab** 切换，标签 **×** 关闭单个会话，**⌘N** 新窗口。

版本：**0.1.0 (1)**。源码：[3809ff6939696ea7d09d4e10a3a7aa11963ad41f](https://github.com/rockdai/pocahontas/commit/3809ff6939696ea7d09d4e10a3a7aa11963ad41f)。许可证保存在 App 的 `Contents/Resources/Notices` 中。包中不含构建机器的用户配置、已保存主机、密码或私钥。

本次打包日期：**2026-11-05**。包含原生 macOS 圆角图标及直接解压为 App 的安装包布局。解压后的签名、公证票据和 Finder 图标均已验证。

将 ZIP 和校验文件下载到同一目录后，在该目录执行：

```sh
shasum -a 256 -c Pocahontas-0.1.0-macos-arm64.zip.sha256
```

结果应显示 `Pocahontas-0.1.0-macos-arm64.zip: OK`。

签名、公证打包使用 `scripts/package-macos.py`，默认输出到 `~/Pocahontas-builds/<提交号>/`；本地 ad-hoc 测试打包使用 `scripts/package-macos-test.sh`，默认输出到 `.build/exports/<提交号>/`。文件名统一为 `Pocahontas-<App 版本>-macos-arm64.zip`，并附带同名 `.sha256` 文件。
