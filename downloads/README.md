# Pocahontas Mac 测试包

[直接下载 Pocahontas（Apple Silicon）](https://github.com/rockdai/pocahontas/raw/refs/heads/main/downloads/Pocahontas-AppleSilicon.zip)

解压后将 **Pocahontas.app** 拖入“应用程序”，即可在另一台 MacBook 上测试，无需安装 Xcode。

- 适用于 Apple 芯片（M1 或更新），项目最低系统 macOS 14；Intel Mac 不适用，最低系统版本仍待实机验收。
- 这是 ad-hoc 签名的 Debug 测试包，未做 Developer ID 签名和 Apple 公证。如果被系统拦截，先尝试打开一次，再到“系统设置 → 隐私与安全性 → 仍要打开”，仅允许这个测试 App。[Apple 操作说明](https://support.apple.com/en-gb/102445)
- 支持 SSH 密码 / Ed25519 私钥连接、并行会话、多窗口和本地连接配置。这个构建不提供密码 / 私钥持久化或 iCloud 同步，连接时重新输入凭据；iCloud 联调需另行完成[签名配置](../docs/icloud-setup.md)。
- **⌘T** 新会话，**⌃Tab / ⌃⇧Tab** 切换，标签 **×** 关闭单个会话，**⌘N** 新窗口。

源码版本：[11b75546921291036793004a2b7e192a00afb88c](https://github.com/rockdai/pocahontas/commit/11b75546921291036793004a2b7e192a00afb88c)。包内也附带源码版本与使用说明。包中不含构建机器的用户配置、已保存主机、密码或私钥。

下载后可在终端校验：

```sh
shasum -a 256 Pocahontas-AppleSilicon.zip
```

结果应与 [SHA256SUMS.txt](SHA256SUMS.txt) 一致。

重新生成安装包使用 `scripts/package-macos-test.sh`，输出在 `.build/exports/`。脚本检查应用名称、架构及签名，并再次解压验证签名。仓库中的 ZIP 是为本次远程测试提供的固定构建，不会随源代码更新自动重建。
