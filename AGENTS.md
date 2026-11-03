# Pocahontas Agent Guidance

参考 [rockdai/baxian 的 AGENTS.md](https://github.com/rockdai/baxian/blob/main/AGENTS.md)，按本项目的 Apple 客户端、Ghostty 集成与 server 设计调整。

## 协作规则

- 使用中文交流，说明实际修改、验证结果和尚未解决的问题。
- 只完成当前任务所需的工作，优先修改已有文件；没有必要不创建文件，没有明确要求不另建说明文档。
- 先检查工作区和相关实现，保留已有未提交修改，不覆盖或回退与本次任务无关的工作。
- 遇到错误、警告或异常，要查明原因并修复或明确交代阻塞原因与后续处理，不能以“不影响”为由跳过，也不能把跳过的检查描述为通过。
- 不提交真实密码、私钥、令牌、验证码、数据库连接凭据或 `.env` 文件。仓库内明确标识的公开 SSH 测试 fixture 仅用于测试，不得用于真实服务。
- 根目录 `AGENTS.md` 是项目规则源文件；`CLAUDE.md` 必须是指向 `AGENTS.md` 的相对符号链接，不维护两份副本。子目录规则仅补充其范围内的约定，用户明确要求优先于仓库约定。

## 产品与架构

- 产品显示名称为 **Pocahontas**，包括 macOS 应用名，不附加 `-macOS`。已有 target、scheme、bundle identifier 等技术名称沿用工程配置，不因显示名要求批量改名。
- 首版同时支持 iPhone、iPad 和原生 macOS；Android、鸿蒙仍在规划中，不提前创建对应客户端或实现尚未需要的功能。
- App、终端和系统弹窗统一固定浅色风格，不跟随系统深色模式，不提供深浅色切换。
- iOS、iPadOS 和 macOS 均支持多个并行 SSH 会话；每个会话独立保存终端、认证与输入状态，切换标签不销毁其他会话。Mac 各窗口的会话相互独立。
- Apple 客户端使用 Swift 6、SwiftUI 与 UIKit / AppKit，共享逻辑放在 `PocahontasKit`；最低系统版本为 iOS / iPadOS 17、macOS 14。
- 终端基于 `ghostty-org/ghostty` 与 `madeye/ghostty` 的 passthru IO 集成；沿用当前锁定的 submodule 和薄 Swift adapter，不自行重写 renderer。
- SSH 由客户端直连用户机器，server 不代理终端流量。保持原始字节顺序、背压和会话回调隔离；首次主机指纹需确认，指纹变化阻断连接，重连不自动重放输入命令。
- 后台的目录与服务名统一为 `server`，不命名为 `backend`。技术栈为 Node.js、阿里云函数计算、PostgreSQL；优先原生能力和 JavaScript ES modules，数据库驱动使用 `pg`，非必要不引入其他依赖。
- 使用统一账号与密文存储方案，不另建同步服务。iCloud 方案已经取消，CloudKit / iCloud Keychain 代码已删除，不能重新引入。
- 产品尚未发布，不为旧版本增加兼容层或数据迁移流程。一个密码完成登录与本机解密，不向用户引入恢复密钥；邮箱重置密码须明确确认清空旧云端加密资料，知道旧密码时修改密码保留资料。
- `server/` 已实现账号 API、验证码邮件适配和密文存储；Apple 客户端已接入密码派生、端到端加密与同步。区分本地验证与云端部署：FC、真实邮件和生产数据库尚待配置与联调，不能将本地测试描述为已上线。

## 项目入口

| 路径 | 用途 |
| --- | --- |
| `Apps/iOS/`、`Apps/macOS/`、`Apps/Shared/` | 平台应用入口、共享界面与会话控制。 |
| `Packages/PocahontasKit/` | 连接库、凭据、SSH 共享逻辑及 Swift Package 测试。 |
| `Terminal/` | Ghostty C ABI 包装、平台渲染宿主与输入适配。 |
| `vendor/ghostty/` | 固定版本的引擎 submodule。 |
| `project.yml`、`scripts/` | XcodeGen 配置和构建、测试、截图入口。 |
| `server/` | server 实现、测试、DDL 与协议。 |
| `Tests/`、`docs/screenshots/` | App 单元 / UI 测试与界面截图。 |

构建前阅读 [README.md](README.md)；架构见 [docs/architecture.md](docs/architecture.md)，账号与数据库约定见 [server/README.md](server/README.md)、[server/schema.sql](server/schema.sql)、[server/protocol.md](server/protocol.md) 和 [server/passwords.md](server/passwords.md)。带有“历史记录”或“已废弃”标记的内容不作为新设计依据。

## 开发与代码风格

- 只实现当前基本需求，禁止为假设中的未来功能过度设计。每个实体和组件保持明确职责，已有概念能表达时不新造实体、层次、状态机或配置项。
- 确定新的技术方案或依赖前，查阅官方文档与相关社区项目；结合当前需求说明取舍，不直接照搬其他项目。已有明确方案的局部实现无需重新开展选型。
- 尽量减少外部依赖。server 首期不引入框架、ORM、Redis、MQ；客户端复用现有 Swift Package，不为每个类型建立新 package。
- 默认用命名、结构和小函数表达逻辑；注释只简短解释不明显的约束与原因，不复述代码、不把设计争论或大段说明写进注释。保留必要的许可证声明和工具指令。
- Swift 源文件与测试文件沿用主要类型的 PascalCase，例如 `SSHConnection.swift`、`SSHCoreTests.swift`；Swift 符号遵循语言惯例，现有 Apple 目录结构不强制改为 kebab-case。
- 新增 server 源文件、脚本和普通文档使用小写 kebab-case，单个单词使用小写。保留 `Package.swift`、`Package.resolved`、`Info.plist`、`README.md`、`AGENTS.md` 等工具或项目约定名称。
- `project.yml` 是工程配置源，通过 `scripts/generate-project.sh` 生成 Xcode 工程，不直接修改生成的 `.xcodeproj`；依赖升级同步维护版本锁。
- Ghostty 的版本、头文件、Swift adapter 和构建脚本一起维护。补丁只作用于项目控制的源码或缓存，不修改系统 Zig 安装或其他项目的共享缓存；生成的 `Frameworks/` 不入库。
- 不记录真实 SSH 凭据、账号密码材料、密文内容、终端输出或剪贴板；诊断信息保留必要的错误类型和阶段。

## 数据库设计规范

### 范围与简洁性

- 使用 PostgreSQL，只保留满足当前功能的表、字段和索引；新增内容必须有当前业务依据，不为未来团队、设备管理、订阅、审计或历史版本预留结构。
- 首期只有 `app_user`、`verification`、`rate_limit` 三张表；账号与当前整份 SSH 资料密文放在同一条用户记录中，不拆出设备、会话、独立密文库或密钥表。
- 数据库结构以 [server/schema.sql](server/schema.sql) 为准；调整时同步更新 SQL 示例、相关文档，以及届时已有的调用代码和必要验证，不能只改 DDL。

### 表名、字段与索引

- 表名与字段名使用小写 snake_case，优先单数、含义明确的名称；避开保留字，用户表使用 `app_user`，不使用需要反复加引号的 `user`。
- 计数字段使用 `_count`，例如 `hit_count`；时间字段使用 `_at`。`expires_at` 是动词表达，不因单数规则改名。
- 每张表的前三个字段严格按 `created_at`、`updated_at`、`deleted_at` 排列，类型使用 `timestamptz`；需要毫秒并发比较的时间使用 `timestamptz(3)`。创建和更新时间必填，删除时间可空。
- 其余字段按相关功能分组，例如标识与邮箱、密码验证信息、加密参数与密文；使用空行分组，DDL 中不写注释。
- 普通索引命名为 `idx_{表名}_{字段名}`，唯一索引命名为 `uk_{表名}_{字段名}`；多个字段按索引中的先后顺序用下划线平铺，不使用缩写或省略字段。
- 主键和 UNIQUE 约束也显式使用对应的 `uk_` 名称，例如 `uk_app_user_id`、`uk_app_user_email`，使其生成的索引遵守相同规则，不另建重复索引。

### 数据库能力与一致性

- 业务规则、输入校验、状态转换和关联归属由 Node.js 代码处理；数据库只承担必要的存取、NOT NULL、主键、唯一性和索引能力。
- 不使用显式多语句事务、外键、级联删除、CHECK、触发器、存储过程或显式行锁；也不能通过多写入 CTE 隐藏跨表事务。普通单条 INSERT / UPDATE 的原子性、条件更新和 `ON CONFLICT` 可以使用。
- 如确实需要事务或外键，先列明具体业务场景、必要性与替代方案，取得用户确认后再引入。当前没有已批准的例外。
- ID 与写入时间由应用层生成并维护；普通读取、鉴权和条件写入均过滤 `deleted_at IS NULL`，关联读取需分别检查每张表。
- 软删除不代表清空敏感数据。验证码消费或作废复用 `deleted_at`；密码重置替换旧密文，注销删除用户，过期验证码与限流记录按约定物理清理，不靠软删除冒充已清空。
- 用户行的每次 UPDATE 都检查原 `updated_at`，Node 生成的新值取当前服务端毫秒时间与原值加一毫秒的较大值，避免并发覆盖。不增加 `vault_id`、`vault_version`、`write_id` 或独立版本表。
- `password_updated_at` 仅保存在 `app_user`，用于密码变更后使旧登录令牌失效。不能复用普通保存也会变化的 `updated_at`，也不在验证码表重复存储密码时间或认证版本。
- 多步写入明确处理中断与重试，不假装具有跨表原子性；例如验证码消费后用户更新失败，需要重新申请验证码，不能恢复已消费记录或自动重放清空操作。

### 三张表的已定边界

- `app_user.password_hash` 用一个字段保存服务端密码验证算法、参数、随机盐与验证值；只由 server 生成和校验，不拆出 `verifier`、`verifier_salt`，不保存用户原密码或 `loginSecret`。
- `app_user.salt` 是客户端密码派生所需的公开随机参数；`ciphertext` 保存客户端加密后的完整快照，二者使用 `bytea`。密码派生的数据密钥只留在客户端，不增加 `encrypted_key` 或可下载的解密密钥。
- 注册邮箱必须验证。`password_updated_at IS NULL` 表示待验证、尚未设置密码，不能登录或访问密文；完成注册时一次填齐密码和密文信息，不额外增加账号状态或邮箱验证状态字段。
- `verification` 通过 `user_id` 在应用层关联用户，邮箱从用户表读取；不重复保存 `channel`、`destination`、`purpose`、`attempts`、`used_at` 等字段。消费时间复用 `deleted_at`，有效期使用 `expires_at`。
- `verification.hash` 保存带独立服务端密钥的 HMAC-SHA256 摘要，不保存验证码明文，也不能简化成对短数字验证码做普通无密钥哈希。密钥放在部署配置中，不放数据库。验证码单次有效，期限和校验流程按协议执行。
- 限流规则与次数上限在 Node.js 判断，跨 FC 实例共享计数保存在 `rate_limit.hit_count`；不能只依赖单实例内存，也不为此引入 Redis。数据库原子累计并返回计数，不写入业务阈值；计数失败时拒绝继续校验。
- 普通改密码与邮箱重置都用一条条件 UPDATE 同时保存新密码验证信息、salt、ciphertext 和时间；前者保留资料，后者替换为空资料的密文。密码与同步协议的具体格式遵循现有文档，不因精简命名改变安全语义。

## 验证规则

- 代码改动后运行与影响范围匹配的本地测试；行为变化和缺陷修复补充必要的正常路径及边界回归测试，测试行为而非实现细节。纯文档、命名或低影响改动不机械新增测试。
- 先检查现有工具、依赖和脚本，不直接以“没有环境”为由跳过；确实无法验证时，明确报告尝试、阻塞和未验证范围，不把编译通过等同于运行通过。
- 共享 Swift 逻辑：`swift test --package-path Packages/PocahontasKit -j 4`。真实 SSH 验证使用 `scripts/test-ssh.sh`；普通 `swift test` 会跳过需要 fixture 的网络集成测试。
- 账号链路：`npm ci --prefix server`、`npm test --prefix server`、`scripts/test-account.sh`。测试自动创建临时 PostgreSQL，仅监听 Unix socket；需要 `initdb` / `pg_ctl`，可用 `PG_BIN` 指定其目录。账号 UI 与冷启动 Keychain 恢复：`scripts/capture-account-screenshots.sh`。测试邮件只保留在 loopback fixture 内，禁止把测试取码接口打入部署包。
- SSH fixture 的 Python 环境按 README 创建；测试仅使用 loopback 和公开测试身份，不连接用户真实机器或删除已有主机信任记录。
- Mac 原生与 UI 测试使用 `scripts/test-macos.sh`；多会话回归使用 `scripts/test-session-macos.sh`。iOS 单元 / UI 测试按 README 启动 fixture 后使用 `pocahontas` scheme。
- Ghostty 集成变动运行 `scripts/verify-ghostty.sh` 并验证受影响平台的渲染与输入。Keychain 集成测试需要有效签名，不能用 `CODE_SIGNING_ALLOWED=NO` 绕过运行要求。
- UI 变动要在受影响的 iPhone、iPad、Mac 界面验证，每个界面保留多个关键状态截图，必要时覆盖横竖屏；截图放入 `docs/screenshots/` 并随相关变更提交，使用测试数据。自动化超时不能算通过，需排查或明确记录实际窗口验证及剩余限制。
- DDL 或 SQL 示例变动时，在临时 PostgreSQL 中验证建表及相关 SQL，不操作真实用户数据库；核对表名、字段顺序、索引名称和旧引用。此验证不代表业务 API 或客户端功能已实现。
- 文档变动检查链接、路径、示例与当前实现是否一致，并运行 `git diff --check`；新增文件也需检查格式。验证完成后无需反复运行无关测试。

## Git 规则

- 采用分支开发与 PR 合并，禁止直接向 `main` 提交代码。新任务使用有意义的分支名，例如 `feat/account-login`、`fix/session-reconnect`、`docs/agent-guidance`；同一未合并任务的改进继续使用原分支。
- 提交前审阅 diff 并完成相关验证，只暂存本次任务的文件，不把已有未提交修改混入提交；不提交生成工程、构建缓存、Ghostty 二进制或真实凭据。
- 提交、推送、PR 和合并状态要如实区分；未推送的修改只能说明已在本地完成，不能在 PR 评论或交付说明中声称已经上线、合并或可从远端下载。用户已要求提交或推送时，继续执行到相应步骤，不重复请求确认。
- 不擅自重写已有提交历史或强制推送；用户明确要求合并历史时，先检查分支与远端状态再处理。
- 分支合并到远程 `main` 后，确认工作区修改安全，再同步本地 `main`、切回并删除已合并的本地分支。
