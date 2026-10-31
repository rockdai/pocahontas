# macOS M0 界面截图

2026-10-31 · macOS 26.4.1 · Apple Silicon · 20 张原始窗口截图。App 与 Ghostty 终端始终使用浅色外观。

截图通过 Computer Use 操作真实原生 App 后直接保存，没有模拟界面或后期改图。窗口左上角的紫色屏幕共享标识和鼠标高亮来自当前 macOS 测试环境。测试服务仅绑定 loopback，回显输入，不执行 shell 命令；截图中的账号、口令、私钥和指纹都属于仓库的公开测试 fixture。

已实际验证密码与加密 Ed25519 认证、文件导入、首次信任与拒绝、⌘C / ⌘V、多行粘贴、双窗口独立连接、关闭单个窗口及窗口放大后 PTY resize。

## 连接配置

| 状态 | 截图 |
| --- | --- |
| 空白连接表单 | <a href="01-connection-empty.png"><img src="01-connection-empty.png" width="520" alt="Mac 空白连接表单"></a> |
| 密码认证 | <a href="02-connection-password.png"><img src="02-connection-password.png" width="520" alt="Mac 密码认证"></a> |
| SSH 私钥模式 | <a href="03-connection-key.png"><img src="03-connection-key.png" width="520" alt="Mac SSH 私钥模式"></a> |
| 私钥编辑 | <a href="04-connection-key-editor.png"><img src="04-connection-key-editor.png" width="520" alt="Mac 私钥编辑"></a> |
| 加密测试私钥与口令 | <a href="18-connection-encrypted-key.png"><img src="18-connection-encrypted-key.png" width="520" alt="Mac 加密测试私钥与口令"></a> |

## 文件导入

| 状态 | 截图 |
| --- | --- |
| 系统文件选择器 | <a href="06-import-key-file.png"><img src="06-import-key-file.png" width="520" alt="Mac 系统文件选择器"></a> |
| 选择仓库中的公开测试密钥 | <a href="17-import-selected-key.png"><img src="17-import-selected-key.png" width="520" alt="Mac 选择仓库中的公开测试密钥"></a> |

## 服务器指纹

| 状态 | 截图 |
| --- | --- |
| 私钥连接首次确认 | <a href="07-host-trust.png"><img src="07-host-trust.png" width="520" alt="Mac 私钥连接首次确认"></a> |
| 密码连接首次确认 | <a href="20-host-trust-password.png"><img src="20-host-trust-password.png" width="520" alt="Mac 密码连接首次确认"></a> |

## 终端与窗口

| 状态 | 截图 |
| --- | --- |
| 加密 Ed25519 连接成功 | <a href="09-terminal-connected.png"><img src="09-terminal-connected.png" width="520" alt="Mac 加密 Ed25519 连接成功"></a> |
| 桌面键盘输入 | <a href="10-terminal-input.png"><img src="10-terminal-input.png" width="520" alt="Mac 桌面键盘输入"></a> |
| 选区与复制 | <a href="11-terminal-selection.png"><img src="11-terminal-selection.png" width="520" alt="Mac 选区与复制"></a> |
| 确认粘贴后的回显 | <a href="13-terminal-after-paste.png"><img src="13-terminal-after-paste.png" width="520" alt="Mac 确认粘贴后的回显"></a> |
| 独立新连接窗口 | <a href="14-new-connection-window.png"><img src="14-new-connection-window.png" width="520" alt="Mac 独立新连接窗口"></a> |
| 放大窗口与远端 resize 回显 | <a href="19-terminal-zoomed.png"><img src="19-terminal-zoomed.png" width="520" alt="Mac 放大窗口与远端 resize 回显"></a> |

## 粘贴确认

| 状态 | 截图 |
| --- | --- |
| ⌘V 多行预览 | <a href="12-paste-preview.png"><img src="12-paste-preview.png" width="520" alt="Mac ⌘V 多行预览"></a> |

## 错误提示

| 状态 | 截图 |
| --- | --- |
| 无效私钥 | <a href="05-error-invalid-key.png"><img src="05-error-invalid-key.png" width="520" alt="Mac 无效私钥"></a> |
| 拒绝信任 | <a href="08-error-trust-declined.png"><img src="08-error-trust-declined.png" width="520" alt="Mac 拒绝信任"></a> |
| 错误密码 | <a href="15-error-authentication.png"><img src="15-error-authentication.png" width="520" alt="Mac 错误密码"></a> |
| 无效端口 | <a href="16-error-invalid-port.png"><img src="16-error-invalid-port.png" width="520" alt="Mac 无效端口"></a> |

## 自动回放边界

`scripts/test-macos.sh` 提供原生单元测试和 16 个基础界面状态的 XCUITest 回放 / 导出入口。本机原生单元测试全部通过，但 XCUITest 在开始操作前报 `Timed out while enabling automation mode`，因此本目录这一轮来自 Computer Use 实际窗口操作，不能算作 XCUITest 通过。文件选择、加密私钥和放大窗口的 17–20 号截图为额外人工流程，不由该脚本覆盖。

脚本在随机 loopback 端口启动 fixture，保留 `.build/macos-tests.*/macOS.xcresult` 和测试日志；每次新端点验证首次信任，不删除已有主机指纹。
