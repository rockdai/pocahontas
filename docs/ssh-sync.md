# SSH 连接库与 iCloud 同步

设计日期：2026-10-25。适用范围为同一用户在 iOS / iPadOS 与未来原生 macOS App 之间共享 SSH 连接资料。

推荐 **本地优先的连接库 + CloudKit private database 同步配置 + iCloud Keychain 同步可导出的凭据**。用户只面对一个连接库，无需注册 pocahontas 账号。用户可完全关闭同步，也可只同步配置、将特定私钥留在本机。

「保存到一个地方」在产品上意味着统一管理和跨设备可用，不必让主机列表和私钥共用一种存储。CloudKit 适合结构化记录；Keychain 适合秘密。两者分别提供能力，也意味着实现必须处理到达顺序不同的情况。

## 社区案例与取舍

| 路线 | 已核对的案例或机制 | 对本项目的判断 |
| --- | --- | --- |
| CloudKit + Keychain | Blink 用 private CloudKit 同步 host，使用 Keychain 管理本地密码 / 私钥；Apple 提供跨设备同步 API。 | 采用原生存储分工，适合当前 Apple 平台范围，无需运营账号服务。 |
| 自有端到端加密 vault | Termius 提供跨平台的加密 vault，同步 hosts、keys 等数据。 | 借鉴统一连接库体验；Android / Windows 或团队共享成为需求时再考虑自建服务。 |
| iCloud Drive 中的 JSON / SSH config | 可作为文件导入导出载体。 | 首版不作为实时数据库；整文件并发修改和凭据管理仍需自行解决。 |
| iCloud key-value store | Apple 面向小型设置的同步机制，总容量 1 MB、最多 1024 个 key。 | 可用于少量偏好，不作为带关系、删除和冲突状态的连接库。 |
| 全部放 Keychain | 可以同步秘密。 | 不适合承担配置查询、工作区关系和可解释的记录冲突。 |

来源：[Blink CloudKit handler](https://github.com/blinksh/blink/blob/a90b4423c8b7a86770c24a7eaa6c13b0a5904b18/Settings/Network/BKiCloudSyncHandler.m)、[Blink 私钥存储](https://github.com/blinksh/blink/blob/a90b4423c8b7a86770c24a7eaa6c13b0a5904b18/BlinkConfig/BKPubKey.m)、[Termius vault 产品说明](https://www.termius.com/free-ssh-client-for-mac-os)、[Apple key-value store 限制](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore)。这些来源支持其已有能力；右列是本项目的选择。

Blink 的实现不能直接视为本项目的安全模板：所核对版本的 `BKHosts.recordFromHost` 还会把 `host.password` 写入普通 CKRecord 字段，pocahontas 不采用这个做法。Blink 源文件带 GPL 声明，本项目只借鉴设计，不复制其实现。[Blink host record 映射](https://github.com/blinksh/blink/blob/a90b4423c8b7a86770c24a7eaa6c13b0a5904b18/BlinkConfig/BKHosts.m)

## 存什么，同步什么

| 数据 | 本地权威存储 | 跨设备行为 |
| --- | --- | --- |
| 主机名称、hostname、port、username、分组 | 本地数据库 | 用户开启后通过 CloudKit 同步。 |
| 工作目录、tmux session 标识、工作区名称 | 本地数据库 | 通过 CloudKit 同步；它们是会话入口，不是运行状态。 |
| SSH 身份名称、公钥、指纹、认证材料引用 | 本地数据库 | 通过 CloudKit 同步；不包含私钥和 passphrase。 |
| 软件私钥、保存的 SSH 密码 | Keychain | 逐身份选择 iCloud Keychain 或仅本机。 |
| 私钥 passphrase | 默认仅当前解锁会话内存 | 如用户选择保存，则作为独立 Keychain 凭据，并单独选择同步。 |
| 已信任服务器的 host key | 本机 trust store，放 Keychain | 首版不同步信任授权，新设备首次连接重新确认。 |
| Secure Enclave 身份 | 本机 Secure Enclave + Keychain 引用 | 后续支持；私钥不迁移，其他设备可配置自己的身份。 |
| 活动 SSH channel、临时输入、终端历史、滚动位置 | 当前会话内存 | 不同步；终端输出默认不持久化。 |
| 字号、窗口大小、软键盘状态 | 本机设置 | 首版保持设备独立，避免 iPhone 字号覆盖 Mac。 |

主机地址、用户名和目录也有隐私价值，CloudKit 字段从第一版使用 `encryptedValues`。服务器可见部分仅保留随机记录 ID、类型、必要 schema 信息和平台系统元数据；不把 hostname 放进 recordName。通过 zone 增量变化拉取，在本地查询和排序，因为 encrypted fields 不能建查询索引。[Apple encryptedValues](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues)

**加密承诺必须区分数据类型：** iCloud Keychain 是端到端加密；CloudKit private database 本身并不等于端到端加密。Apple 文档说明，CloudKit encrypted fields 在开启 Advanced Data Protection 后获得相应端到端保护。因此首版不能宣传「所有连接元数据在任何 iCloud 设置下都对 Apple 不可见」。[Apple iCloud 安全说明](https://support.apple.com/en-us/102651)

如果将来要求所有元数据在未开启 ADP 时也端到端加密，可将每条 CloudKit payload 改为客户端 AEAD 加密、密钥置于同步 Keychain；届时必须补齐密钥恢复、轮换与多设备首次创建流程。当前需求不要求这一额外密码体系，首版采用系统能力并准确说明保护范围。

## 数据模型

下列名称定义边界，不要求每项独立成库。

| 模型 | 核心字段与约束 |
| --- | --- |
| `HostProfile` | UUID、displayName、endpoint（hostname / port / username）、authentication（identityID 或 passwordCredentialID）、标签、schemaVersion、删除标记。endpoint 与 authentication 作为一个冲突单元。 |
| `SSHIdentity` | UUID、名称、algorithm、publicKey、SHA256 fingerprint、storagePolicy、secretRevisionID；只保存公有材料与引用。 |
| `WorkspaceBookmark` | UUID、hostID、remoteDirectory、tmuxSessionName、可选 startupCommand；命令不得嵌入密码或 token，且不会在同步或重连时自动执行。 |
| `CredentialReference` | ownerScope、credentialID、revisionID、kind；Keychain 使用这一稳定逻辑地址查找秘密，不保存设备特有 persistent reference。 |
| `KnownHost` | 规范化 hostname、port、algorithm、公钥及确认时间；本机保存，与显示名无关；同主机不同用户名共享同一 trust 判断。 |

每条记录有独立 UUID，重命名不改变身份。CloudKit 使用一个 private custom zone，例如 `Connections-v1`；按模型存记录，秘密始终排除在 CloudKit DTO 之外。用户可见内容封装进 `encryptedValues["payload"]`，解码后再进行逻辑字段合并；schema 迁移新增字段，不能假设可将已部署的普通字段原地改成 encrypted field。

设备专属认证覆盖单独存本地：例如 iPhone 和 Mac 都连接同一主机，但分别使用各自仅本机身份。云端 host 可以引用共享身份，本机覆盖只替换本机连接所选的身份，不修改其他设备。第一版只需支持「此设备选择另一个身份」，不实现复杂策略系统。

主机删除不会级联删除一个可能被其他主机使用的 SSH 身份；删除身份时显示受影响连接，连接保留但标记为需要重新配置认证。

## 本地与 CloudKit 同步

选择 **本地 Core Data store + CKSyncEngine**。Core Data 仅负责本地事务与查询，不同时开启 `NSPersistentCloudKitContainer` 或 SwiftData 自动 CloudKit 同步，避免两套同步机制写同一数据。`CKSyncEngine` 管理同步调度和变化传输，应用负责 record 映射、冲突、账号隔离与状态持久化。[Apple CKSyncEngine 示例](https://github.com/apple/sample-cloudkit-sync-engine)、[Apple 同步介绍](https://developer.apple.com/videos/play/wwdc2023/10188/)

用户操作先本地提交；UI 和 SSH 连接不等待云端。关闭网络或 CloudKit 不可用时，仍能编辑并使用本机已有配置和凭据。开启同步是连接库级选择；关闭配置同步不会偷偷删除云端记录。

同步需要持久化三个部分：本地记录、待发送的修改 / 删除，以及服务端版本信息和 engine state serialization。记录与待发送标记在同一个本地事务中写入；启动时从未确认的标记恢复 pending changes。engine state 事件及时落盘，发送成功后仅清除对应版本的待发送项，不能清掉用户之后的新修改。

连接库操作与同步回调经串行协调器处理。record ID 固定，因此恢复重试仍是同一条记录。首次同步和重新联网时先合并远端变化，再发送尚未同步的本地修改；本地修改不能被一次 fetch 覆盖。进入前台和用户点击同步时可主动请求同步，推送作为通知机制；不承诺固定同步时延。

### 冲突和删除

- 保存服务端 `recordChangeTag` 等系统字段，使用乐观并发。出现 server-record-changed 后做 base / local / remote 三方比较，不依赖设备时间戳决定胜负。
- 不同字段的修改可合并；同字段不同内容保留冲突双方。影响连接的 endpoint + authentication 作为整体，避免合并出从未被用户选择过的地址与凭据组合。未解决前禁止用冲突配置新建连接，现有连接仍使用连接时的配置快照。
- 删除使用持久 tombstone；删除优先于离线旧编辑，原记录不会被旧设备复活。可显式恢复为新 UUID。首版数据量小，先不自动清理 tombstone；以后引入清理时必须设计旧设备重新同步语义。
- CloudKit 拒绝、限流或容量不足时保留本地数据和待发送项，显示可操作错误。未知新版 schema 保留原始记录并禁用编辑，不能当空配置回写。
- zone 不存在或加密数据不可读时进入恢复状态，不立即以本地旧缓存覆盖整个云端库。由明确的恢复动作选择重新下载或重建。

关闭本机同步、删除某条记录、删除整个云端库是不同操作；UI 必须区分影响范围。首版不提供一键清空云端库，先做好单条删除与同步停用。

### 两条同步通道没有事务

CloudKit 配置可能先到，Keychain 私钥后到，也可能相反。UI 必须将「有配置」与「能认证」分开：

| 情况 | 展示与行为 |
| --- | --- |
| 配置与秘密均本机可用 | 允许连接；实际是否可达仍需 SSH 握手。 |
| 配置已到、秘密查不到 | 显示「凭据尚未在此设备可用」，可稍后重试、导入或选择本机身份；不宣称一定正在同步。 |
| 身份仅另一台设备可用 | 显示「需要在此设备配置身份」；不自动改成密码认证。 |
| Keychain 因设备锁定不可读 | 保留凭据引用，等待解锁；不能当作缺失或执行删除。 |
| 秘密到达但配置未到 | 保留未引用条目，不创建臆测的 host，也不立即清理。 |

保存新凭据时先写 Keychain 并确认本机写成功，再在本地事务中发布其引用并排队同步。不向 UI 承诺另一台设备已收到，因为应用不能从一次 `SecItemAdd` 成功推断 iCloud Keychain 同步完成。

凭据替换采用新的 revision UUID，成功后更新配置引用，不原地覆盖同一 Keychain 地址。这样两台设备并发修改时，秘密版本分别存在，冲突发生在可处理的 CloudKit 引用层。旧版本不能仅因为本机暂时没有引用就自动删除；首版保留到用户明确删除身份，避免慢设备仍引用它。

## Keychain 具体约定

使用 Security framework 的 `SecItem` API。可导出的软件私钥可按原始 key blob 存为 generic-password Data，避免依赖所有 SSH 文件格式都能直接映射为 `SecKey`；拿到后交给验证过的 SSH 认证材料解析器。公钥 fingerprint 用于验证秘密与身份记录匹配，不以名称匹配私钥。

| 属性 | 跨设备凭据 | 仅本机凭据 |
| --- | --- | --- |
| `kSecClass` | `kSecClassGenericPassword` | 同左 |
| `kSecAttrService` | 产品固定、跨平台相同的 service 名 | 同左或明确的本机 service |
| `kSecAttrAccount` | `ownerScope/credentialID/revisionID/kind` | 独立 local scope 下的逻辑地址 |
| `kSecAttrAccessGroup` | 两个平台均获授权的同一 Keychain group | 同组，但同步属性明确为 false |
| `kSecAttrSynchronizable` | `true` | `false` |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlocked` | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| macOS keychain | Data Protection Keychain | 显式 `kSecUseDataProtectionKeychain = true` |

同步 item 不能搭配 `ThisDeviceOnly`，也不能用 persistent reference 作为跨设备地址。普通查找和删除指定 scope、service、account 与同步属性，避免用宽泛的 `SynchronizableAny` 查询造成误取或误删。保留 OSStatus 区分未找到、锁定、缺失 entitlement 等错误，不把所有失败压成 nil。[Apple synchronizable 约束](https://developer.apple.com/documentation/security/ksecattrsynchronizable)、[macOS Keychain 选择](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)

密码和私钥同步逐项启用；首次导入默认仅本机，选择「在我的 Apple 设备间同步」后才创建同步条目。连接库可以同步主机元数据而不同步秘密。已开启同步的秘密不受本应用 CloudKit 开关直接控制，因此设置中单独列出凭据同步状态。

「停止共享此凭据」需先创建并验证本机条目、更新本机绑定，再删除指定同步条目。删除 synchronizable item 会影响其他设备，不是只删本机缓存；结果通过系统逐步传播，不能承诺立即撤回离线设备上的材料。删除 App 中的私钥也不等于从远端 `authorized_keys` 撤销公钥，这两种操作要分开表达。

首版不把 Secure Enclave 作为跨设备私钥方案。Apple Security API 下的 Secure Enclave 私钥由所在硬件生成并使用，不能把导入的 OpenSSH key 放进去再迁移到另一台设备；相关 API 的算法范围也不同于常用 Ed25519。[Apple Secure Enclave 说明](https://developer.apple.com/documentation/security/protecting-keys-with-the-secure-enclave)

## iCloud 账号、签名与恢复

跨设备可用需要同时满足：同一 Apple Account、对应系统同步服务可用、两个 App 使用同一 CloudKit container、两个 target 的签名均授权相同 Keychain access group。App Groups 的本机共享容器不能替代这两项跨设备能力。[Apple Keychain sharing](https://developer.apple.com/documentation/xcode/configuring-keychain-sharing)

建议预留 `iCloud.<bundle-root>.pocahontas` 和 `$(AppIdentifierPrefix)<bundle-root>.pocahontas.shared`，实际名称在确认开发团队与 bundle 命名后注册，不复用 baxian 的 Team ID。开发 / 生产 CloudKit schema、推送 entitlement、后台 remote notification 和 macOS network client capability 在 target 中显式配置；上线前将 schema 部署到 production。不同开发环境使用隔离的本地与 Keychain service 命名，避免测试条目污染正式凭据。

没有 Apple Account 或关闭系统同步时进入本地模式，不阻止 SSH 使用。iCloud 账号状态与 Keychain item 可读性分别处理；无法仅根据 CloudKit account status 判断某条秘密是否已经同步。

本地数据分为 local-only scope 与按 CloudKit 用户身份隔离的 account scope。收到真实 sign-out / account-switch 时停止旧账号同步，关闭绑定该 scope 的会话、清空其内存解锁材料，并隔离缓存与待发送项；新账号只加载自己的 scope。临时网络错误不视为退出账号。旧账号数据不能自动上传到新账号，local-only 数据也只在用户开启同步时明确加入所选账号。

Keychain 查询使用对应 ownerScope，避免应用将旧账号凭据绑定给新账号配置。此隔离约束应用自己的查找与写入，不宣称能控制系统 iCloud Keychain 的全部账号迁移行为。切换账号不批量删除同步 Keychain，以免连带删除其他设备的数据。

本地数据库与队列使用文件保护，日志不记录 payload 或凭据。恢复时，配置由 CloudKit 重新下载，秘密由 Keychain 提供；仅本机身份需要在原设备备份或重新配置。iCloud 同步不是独立备份，记录删除也会传播。导出功能先只提供不含秘密的连接信息；私钥导出和独立加密备份另行设计。

## 验收场景

以下必须进入同步集成测试，不能只靠模拟数据或一次单设备写入证明成功：

1. iPhone 创建主机与同步身份，另一台 iOS 设备及 macOS 验证宿主收到后能选中同一身份完成认证；只在新设备首次连接确认 host key。
2. 两设备离线修改不同字段可以合并；并发修改 endpoint / authentication 进入可见冲突，绝不静默组合。
3. 设备 A 删除主机，离线设备 B 修改旧主机再上线，删除不被复活；共享身份仍供其他主机使用。
4. 配置先到、凭据先到、凭据一直不到、设备锁定分别有正确状态；均不会自动降级认证或删除引用。
5. 仅本机密钥不创建 synchronizable item；另一设备配置自己的身份不会改掉原设备的绑定。
6. 凭据更新失败不丢失旧值；两设备并发替换凭据能保留版本并解决引用冲突。
7. 关闭 CloudKit 同步后系统 Keychain 状态符合单独设置；停止共享凭据先验证本机副本，再处理跨设备删除。
8. CloudKit 限流、断网、容量不足、App 在落盘 / 发送中被终止后，修改仍可恢复；未确认修改不会被误标为已同步。
9. 退出或切换 Apple Account 不混用配置，不上传旧账号缓存，不批量删除旧账号同步秘密。
10. Debug / release 的签名、共同 access group、CloudKit production schema 和真实设备通知链路均验证通过。

Apple 的 CKSyncEngine 示例适合作为同步调度与测试参考；主机冲突和双存储引用是本项目自己的业务规则。上线前需用真实签名与设备验证，不能用模拟器单机成功替代跨平台验收。
