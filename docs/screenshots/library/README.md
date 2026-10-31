# 连接库与 iCloud 界面

2026-11-01：46 张实际运行截图，iPhone 20 张、iPad 20 张、Mac 6 张。全部保持浅色外观，未重绘、拼接或修饰界面。

iPhone 17 Pro 与 iPad Pro 11-inch (M5) 使用 iOS / iPadOS 26.5 模拟器。系统为深色，App 固定浅色。测试通过真实本机 Keychain 保存密码，重启 App 后连接 loopback SSH fixture，并导入测试 Ed25519 key；图中的私钥为仓库公开的测试材料，不能用于真实服务器。

同步设置如实显示当前本地开发构建没有 iCloud 权限。这些图片验证界面与本地功能，不证明 CloudKit 或 iCloud Keychain 已跨设备同步。容器授权和真机验收见 [iCloud 构建说明](../../icloud-setup.md)。

Mac 截图由 Computer Use 操作真实 App 窗口保存；本轮 XCTest 等待 IDE 测试会话建立，未执行完成，后续 Computer Use 也无法获取新启动的可截图窗口，因此本轮仅保留已实际截取的 6 张，不以模拟图补齐。

重新运行 iPhone / iPad 截图：`scripts/capture-library-screenshots.sh`。脚本仅创建、使用并删除本次专用模拟器与 SSH fixture。

## iPhone 与 iPad

| Screen | iPhone | iPad |
| --- | --- | --- |
| 01 library empty | <a href="iphone/01-library-empty.png"><img src="iphone/01-library-empty.png" width="240" alt="iPhone 01 library empty"></a> | <a href="ipad/01-library-empty.png"><img src="ipad/01-library-empty.png" width="320" alt="iPad 01 library empty"></a> |
| 02 library empty landscape | <a href="iphone/02-library-empty-landscape.png"><img src="iphone/02-library-empty-landscape.png" width="240" alt="iPhone 02 library empty landscape"></a> | <a href="ipad/02-library-empty-landscape.png"><img src="ipad/02-library-empty-landscape.png" width="320" alt="iPad 02 library empty landscape"></a> |
| 03 icloud settings | <a href="iphone/03-icloud-settings.png"><img src="iphone/03-icloud-settings.png" width="240" alt="iPhone 03 icloud settings"></a> | <a href="ipad/03-icloud-settings.png"><img src="ipad/03-icloud-settings.png" width="320" alt="iPad 03 icloud settings"></a> |
| 04 icloud settings landscape | <a href="iphone/04-icloud-settings-landscape.png"><img src="iphone/04-icloud-settings-landscape.png" width="240" alt="iPhone 04 icloud settings landscape"></a> | <a href="ipad/04-icloud-settings-landscape.png"><img src="ipad/04-icloud-settings-landscape.png" width="320" alt="iPad 04 icloud settings landscape"></a> |
| 05 add connection | <a href="iphone/05-add-connection.png"><img src="iphone/05-add-connection.png" width="240" alt="iPhone 05 add connection"></a> | <a href="ipad/05-add-connection.png"><img src="ipad/05-add-connection.png" width="320" alt="iPad 05 add connection"></a> |
| 06 add connection password | <a href="iphone/06-add-connection-password.png"><img src="iphone/06-add-connection-password.png" width="240" alt="iPhone 06 add connection password"></a> | <a href="ipad/06-add-connection-password.png"><img src="ipad/06-add-connection-password.png" width="320" alt="iPad 06 add connection password"></a> |
| 07 library saved | <a href="iphone/07-library-saved.png"><img src="iphone/07-library-saved.png" width="240" alt="iPhone 07 library saved"></a> | <a href="ipad/07-library-saved.png"><img src="ipad/07-library-saved.png" width="320" alt="iPad 07 library saved"></a> |
| 08 library saved landscape | <a href="iphone/08-library-saved-landscape.png"><img src="iphone/08-library-saved-landscape.png" width="240" alt="iPhone 08 library saved landscape"></a> | <a href="ipad/08-library-saved-landscape.png"><img src="ipad/08-library-saved-landscape.png" width="320" alt="iPad 08 library saved landscape"></a> |
| 09 saved connection | <a href="iphone/09-saved-connection.png"><img src="iphone/09-saved-connection.png" width="240" alt="iPhone 09 saved connection"></a> | <a href="ipad/09-saved-connection.png"><img src="ipad/09-saved-connection.png" width="320" alt="iPad 09 saved connection"></a> |
| 10 saved connection landscape | <a href="iphone/10-saved-connection-landscape.png"><img src="iphone/10-saved-connection-landscape.png" width="240" alt="iPhone 10 saved connection landscape"></a> | <a href="ipad/10-saved-connection-landscape.png"><img src="ipad/10-saved-connection-landscape.png" width="320" alt="iPad 10 saved connection landscape"></a> |
| 11 saved terminal | <a href="iphone/11-saved-terminal.png"><img src="iphone/11-saved-terminal.png" width="240" alt="iPhone 11 saved terminal"></a> | <a href="ipad/11-saved-terminal.png"><img src="ipad/11-saved-terminal.png" width="320" alt="iPad 11 saved terminal"></a> |
| 12 saved terminal landscape | <a href="iphone/12-saved-terminal-landscape.png"><img src="iphone/12-saved-terminal-landscape.png" width="240" alt="iPhone 12 saved terminal landscape"></a> | <a href="ipad/12-saved-terminal-landscape.png"><img src="ipad/12-saved-terminal-landscape.png" width="320" alt="iPad 12 saved terminal landscape"></a> |
| 13 identities empty | <a href="iphone/13-identities-empty.png"><img src="iphone/13-identities-empty.png" width="240" alt="iPhone 13 identities empty"></a> | <a href="ipad/13-identities-empty.png"><img src="ipad/13-identities-empty.png" width="320" alt="iPad 13 identities empty"></a> |
| 14 identities empty landscape | <a href="iphone/14-identities-empty-landscape.png"><img src="iphone/14-identities-empty-landscape.png" width="240" alt="iPhone 14 identities empty landscape"></a> | <a href="ipad/14-identities-empty-landscape.png"><img src="ipad/14-identities-empty-landscape.png" width="320" alt="iPad 14 identities empty landscape"></a> |
| 15 import identity | <a href="iphone/15-import-identity.png"><img src="iphone/15-import-identity.png" width="240" alt="iPhone 15 import identity"></a> | <a href="ipad/15-import-identity.png"><img src="ipad/15-import-identity.png" width="320" alt="iPad 15 import identity"></a> |
| 16 import identity key | <a href="iphone/16-import-identity-key.png"><img src="iphone/16-import-identity-key.png" width="240" alt="iPhone 16 import identity key"></a> | <a href="ipad/16-import-identity-key.png"><img src="ipad/16-import-identity-key.png" width="320" alt="iPad 16 import identity key"></a> |
| 17 identities saved | <a href="iphone/17-identities-saved.png"><img src="iphone/17-identities-saved.png" width="240" alt="iPhone 17 identities saved"></a> | <a href="ipad/17-identities-saved.png"><img src="ipad/17-identities-saved.png" width="320" alt="iPad 17 identities saved"></a> |
| 18 identities saved landscape | <a href="iphone/18-identities-saved-landscape.png"><img src="iphone/18-identities-saved-landscape.png" width="240" alt="iPhone 18 identities saved landscape"></a> | <a href="ipad/18-identities-saved-landscape.png"><img src="ipad/18-identities-saved-landscape.png" width="320" alt="iPad 18 identities saved landscape"></a> |
| 19 delete identity confirmation | <a href="iphone/19-delete-identity-confirmation.png"><img src="iphone/19-delete-identity-confirmation.png" width="240" alt="iPhone 19 delete identity confirmation"></a> | <a href="ipad/19-delete-identity-confirmation.png"><img src="ipad/19-delete-identity-confirmation.png" width="320" alt="iPad 19 delete identity confirmation"></a> |
| 20 replace identity | <a href="iphone/20-replace-identity.png"><img src="iphone/20-replace-identity.png" width="240" alt="iPhone 20 replace identity"></a> | <a href="ipad/20-replace-identity.png"><img src="ipad/20-replace-identity.png" width="320" alt="iPad 20 replace identity"></a> |

## Mac

### 01 library empty

[<img src="mac/01-library-empty.png" width="620" alt="Mac 01 library empty">](mac/01-library-empty.png)

### 02 icloud settings

[<img src="mac/02-icloud-settings.png" width="620" alt="Mac 02 icloud settings">](mac/02-icloud-settings.png)

### 03 add connection

[<img src="mac/03-add-connection.png" width="620" alt="Mac 03 add connection">](mac/03-add-connection.png)

### 04 add connection filled

[<img src="mac/04-add-connection-filled.png" width="620" alt="Mac 04 add connection filled">](mac/04-add-connection-filled.png)

### 06 saved connection

[<img src="mac/06-saved-connection.png" width="620" alt="Mac 06 saved connection">](mac/06-saved-connection.png)

### 07 saved connection ready

[<img src="mac/07-saved-connection-ready.png" width="620" alt="Mac 07 saved connection ready">](mac/07-saved-connection-ready.png)
