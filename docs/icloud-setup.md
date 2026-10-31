# iCloud 同步构建与验收

更新：2026-11-01。本轮已实现连接库、CloudKit 传输和 Keychain 凭据存储；**真实 Apple Account 的跨设备同步尚未验收，不应据此发布正式版**。

## 已实现的范围

- iPhone、iPad、原生 Mac 共用已保存主机、Ed25519 身份、同步设置和冲突审阅界面，入口为快速连接页右上角 **Saved Connections**。
- Core Data 本地事务保存每个账号的记录、待上传修改、服务端系统字段和 CKSyncEngine checkpoint。保存与连接不等待网络。
- `CKSyncEngine` 同步 private database 的 `Connections-v1` zone。`HostProfile` 与 `SSHIdentity` 只有一个用户字段 `encryptedValues["payload"]`，值为 JSON Data；recordName 为随机 UUID。无 hostname 索引、无公共数据库记录。
- 密码、私钥只写 Security / Keychain。默认仅本机；在 iCloud 连接库内可逐项选择 iCloud Keychain。先成功写入并读回验证，才发布凭据引用。passphrase 本轮始终只用于当前解锁，不提供保存选项。
- 三方合并不同字段；地址、端口、用户名、认证引用作为一个整体。冲突保留双方并阻止新连接，审阅时保留其他已合并字段。多窗口的过期编辑也会被阻止。
- 删除以永久保留的 tombstone 同步，删除优先于旧编辑。主机删除不删除密钥；身份删除会提示关联主机数量。
- 同步暂停、手动同步、账号隔离、设备专属认证覆盖、凭据尚未到达、设备锁定、未知 schema 和 zone 丢失的处理。换号立即停止旧账号的连接使用路径，旧账号缓存与 outbox 留在各自 scope。
- 初次选择 iCloud 不自动上传本机库。**Copy Local Connections to iCloud** 是明确复制操作；复制后秘密仍为仅本机，不默认开启 Keychain 同步。

Quick Connect 仍只使用一次性凭据。服务器 host-key 信任、终端内容和活动 SSH 会话不同步。

## 签名配置

| 用途 | Scheme / Configuration | 行为 |
| --- | --- | --- |
| iPhone / iPad 本地开发 | `pocahontas` / `Debug` | 模拟器可使用真实本机 Keychain；不开启 CloudKit。 |
| Mac 本地开发 | `pocahontas-macOS` / `Debug` | ad-hoc 签名；可保存配置、连接时输入密码。凭据持久化不可用，因为 Data Protection Keychain 需要正确的 provisioning。 |
| iPhone / iPad 同步联调 | `pocahontas-iCloud` / `CloudDebug` | 开发环境 CloudKit、共享 Keychain group、推送。 |
| Mac 同步联调 | `pocahontas-macOS-iCloud` / `CloudDebug` | 同上，必须由同一团队正式开发签名。 |
| 发布 | `Release` | Production CloudKit；发布前部署 schema 并完成真机验收。 |

工程已提交以下配置，开发团队不硬编码在仓库中：

| 项目 | 值 |
| --- | --- |
| iOS App ID | `com.rockdai.pocahontas` |
| macOS App ID | `com.rockdai.pocahontas.mac` |
| CloudKit container | `iCloud.com.rockdai.pocahontas` |
| 共同 Keychain access group | `$(AppIdentifierPrefix)com.rockdai.pocahontas.shared` |
| Keychain service | `com.rockdai.pocahontas.credentials.v1` |

同一 App ID prefix 的两端才能访问同组条目，不能简单以不同团队的签名替换。仅本机库的凭据继续使用各 App 默认组，以保留从 Debug 升级的访问能力；账号 scope 的本机与同步凭据均使用共同组。所有凭据都使用 Data Protection Keychain；Mac 的 login Keychain 只用于不同步的服务器信任。

### 当前外部阻碍

本轮使用本机已有的 Apple Development 身份执行了自动签名检查。Xcode 已能生成 `com.rockdai.pocahontas.mac` 的 Mac Team Provisioning Profile，但构建仍报告：

```text
doesn't include the com.apple.developer.icloud-container-environment entitlement
doesn't match ... com.apple.developer.icloud-container-identifiers entitlement
```

即该 profile 尚未授权目标 CloudKit container。`cktool get-teams` 同时报告没有管理令牌；这不是 App 的同步成功或失败证据。不要删除 iCloud entitlement 来绕过此错误后宣称同步已验证。

### 在开发团队中完成一次配置

1. 在 Xcode 登录具有容器管理权限的开发团队，选择两个 App target 的 **Signing & Capabilities**。对 `CloudDebug` 选择同一个 Team。
2. 启用 iCloud 的 **CloudKit**，创建或勾选 `iCloud.com.rockdai.pocahontas`，将两个 App ID 都关联到它；两个 target 都启用 Push Notifications 和共同 Keychain group。容器可由同一团队的多个 App 共享，创建/管理需要 Account Holder 或 Admin 权限。[Apple 容器管理说明](https://help.apple.com/xcode/mac/current/en.lproj/devcae40ccb9.html)
3. 刷新自动签名 profile，确认其容器标识、iCloud 环境、共享 group 与提交的 `Cloud.entitlements` 匹配。Xcode 选择容器时会建立 App ID 与容器关联。[Apple 配置 iCloud 服务](https://developer.apple.com/documentation/xcode/configuring-icloud-services/)
4. 在已登录同一 Apple Account、启用 iCloud Keychain 的 Mac 和真实 iPhone / iPad 上运行 iCloud scheme。

命令行构建示例，替换团队值后执行：

```sh
scripts/generate-project.sh
xcodebuild -project pocahontas.xcodeproj -scheme pocahontas-macOS-iCloud \
  -configuration CloudDebug -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates build
```

`project.yml` 是工程配置源。若在 Xcode 中调整配置，需同步回该文件及 entitlement，避免下次生成覆盖。

## CloudKit schema 与上线

首次在 Development 环境成功保存会建立 `HostProfile` / `SSHIdentity` 及其 **加密 Data/Bytes** `payload` 字段。不要先把它建成普通 Bytes；已存在的普通字段不能直接改为 encrypted field。[Apple encryptedValues](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues)

在 CloudKit Console 确认两个 record type 的 `payload` 都是加密字段，然后将 schema 部署至 Production，再运行 Release 的真机同步检查。应用只增量读取 zone，不依赖 payload 的查询索引。配置使用 CloudKit encrypted fields，不能笼统宣传为任何系统设置下都端到端加密；详见[原设计的加密边界](ssh-sync.md)。

## 本轮验证入口

```sh
scripts/test-ssh.sh
scripts/capture-library-screenshots.sh
```

共享测试覆盖真实 SSH 密码与加密 Ed25519 握手，以及 14 项连接库测试：不同字段合并、原子认证冲突、删除优先、旧 ACK 不清除新修改、未知 schema 原样保留、encrypted payload 映射、Core Data 重开、凭据写失败、凭据缺失、账号隔离、本机覆盖、过期编辑、立即换号隔离和存储失败不覆盖原数据。

截图测试使用独立模拟器、真实本机 Keychain 和 loopback SSH 服务：保存密码 → 终止 App → 重开 → 直接连接；导入 fixture Ed25519 key → 验证 Keychain 可用。截图均为未修改的原始截图，且系统设置为深色以验证 App 固定浅色。[截图索引](screenshots/library/README.md)

本轮通过：25 项共享测试（14 项连接库 + 11 项 SSH / PTY）、5 项 iOS App 测试、iPhone 与 iPad 各一条完整界面流程、Mac Debug 构建及 iOS device SDK 编译。账号改变后在 SSH 启动前的再次校验也包含在 iOS App 测试中。Mac XCTest 在建立 IDE 测试会话时未完成，本轮不计为通过；Mac 截图来自实际窗口操作。

这些测试**没有覆盖实际 CloudKit 服务器传输、APNs、跨设备 Keychain 到达顺序或 Production schema**。签名配置完成后，必须按[设计中的十项真机验收](ssh-sync.md#验收场景)执行，并记录设备、系统、构建、账号切换与离线恢复结果。

## 本轮仍保留的边界

- 工作区 / 自动 tmux、私钥 passphrase 持久化、历史 Keychain revision 清理、停止共享凭据的跨设备撤回流程尚未提供。替换凭据或取消选择新 revision 的同步，不删除已经共享的旧 revision；UI 与连接库删除操作都不宣称撤销服务器授权。
- 未知 schema 的数据保留为只读；应用会提示升级，不尝试按旧模型覆盖。
- 检测到 zone / record 被外部物理删除时暂停上传。用户选择 **Reload iCloud Library** 后，旧 snapshot 存为 Core Data 中独立的 `recovery-…` scope，再重新下载；此阶段没有存档导出或自动回灌界面。不要手动删除数据库来“修复”同步。
- 启动时若尚未确认 Apple Account，只展示独立本机库；不凭上次账号名称自动暴露旧账号缓存。已验证账号的一次临时网络错误不会被当作退出账号。
