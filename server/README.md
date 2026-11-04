# Pocahontas server

更新：2026-11-04。已实现账号 API、邮件验证码、密文存储与 Apple 客户端接入，本地端到端测试通过。技术栈为 **Node.js + 阿里云函数计算 + PostgreSQL**；目录与服务名统一使用 `server`。FC 与真实邮件尚未部署联调。

## 首期范围

只实现已需要的功能：邮箱验证注册、密码登录与本机退出、修改密码、邮箱重置密码、个人连接库加密存储与多端同步。用户一次输入密码完成登录与解密；没有恢复密钥。知道旧密码时修改密码保留资料，忘记密码时通过邮箱验证、明确确认后清空旧云端资料。首期不做设备列表或单设备撤销。

iCloud 路线取消，旧数据不迁移，不兼容未发布的旧版本。SSH 仍由客户端直连用户的开发机器，server 不传输终端字节流，也不托管 agent。首期不设计团队、订阅、推送、审计平台、附件、历史版本或自动备份恢复系统。

## 三张表

| 表 | 保存内容 |
| --- | --- |
| `app_user` | 邮箱；验证完成后保存单字段 password_hash、密码派生参数 salt 和当前整份加密连接库。 |
| `verification` | 关联用户、验证码摘要和有效期；消费后填写 deleted_at。 |
| `rate_limit` | 跨 FC 实例共享的验证码/登录尝试计数。 |

见 [schema.sql](schema.sql)。仅保留普通字段、主键、必要的唯一约束和查询索引。长度、枚举、关联归属和状态转换由 Node 校验；没有外键、级联删除、数据库 CHECK、触发器、存储过程、显式行锁或多语句事务。不要通过多写入 CTE 把跨表事务藏在一条 SQL 中。

`app_user.password_hash` 为 text，在一个字段内保存服务端验证使用的算法、迭代次数、随机盐和验证值；只有 server 生成和校验，不通过 API 接收或返回该字段。它校验客户端提交的 loginSecret，不保存用户原密码或 loginSecret。具体格式见 [密码方案](passwords.md#密码派生与数据加密)。

`app_user.salt` 是客户端密码派生所需的公开随机参数，API 也统一命名为 salt。客户端从密码和 salt 按用途派生登录材料与 dataKey，后者直接加密整份 SSH 资料，只存于本机安全存储。password_hash 内部另有独立的服务端随机盐，不作为单独字段，也不与 app_user.salt 复用。app_user 共 9 个字段，不保存可供下载的数据密钥。

表名使用单数，表名与字段名统一采用小写下划线（snake_case）；字段按实际含义命名，计数使用 `_count`，时间使用 `_at`。用户表命名为 `app_user`，避免 PostgreSQL 保留字 `user`。

索引统一命名：普通索引用 `idx_{表名}_{字段名}`，唯一索引用 `uk_{表名}_{字段名}`；多字段按索引定义顺序用下划线平铺，例如 `idx_{表名}_{字段1}_{字段2}`。主键与 UNIQUE 约束显式使用对应的 uk 名称，使其自动建立的唯一索引也遵守规则，不另外建立重复索引。

这里的“不使用事务”指业务代码不执行 BEGIN/COMMIT/ROLLBACK，不依赖多条语句共同提交。PostgreSQL 的单条语句仍有自身的原子提交机制，这是普通 INSERT/UPDATE 的基础行为。[PostgreSQL 说明](https://www.postgresql.org/docs/current/tutorial-transactions.html)

目前没有需要申请事务或外键的例外。若后续确有必要，先列出具体业务场景和替代方案，由用户确认后再采用。

## 通用字段与密码变更时间

每张表的前三个字段固定按 `created_at`、`updated_at`、`deleted_at` 排列，使用 timestamptz。Node 在插入时写入相同的创建/更新时间，之后每次更新都维护 updated_at；不使用数据库触发器。deleted_at 默认为 NULL，非空表示已软删除。普通查询、认证、验证码消费和条件写入都要求 deleted_at IS NULL；关联查询对涉及的每张表分别检查。

`app_user.updated_at` 直接用于同步的并发检查，采用 timestamptz(3)，API 返回 UTC ISO 8601 毫秒字符串。每次 app_user UPDATE（包括注册、修改或重置密码）都要求 updated_at 等于读取的原值；Node 计算新值为 max(当前服务端毫秒时间, 原值 + 1 毫秒)。同一毫秒内的修改和时钟回拨也不会复用时间，不另存连接库编号、版本号或写入编号。其他用户资料修改同样会让旧的保存请求发生冲突，这是复用行更新时间的明确取舍。

软删除不等于清除敏感数据。邮箱重置仍替换原密文、salt 和 password_hash，注销账号仍实际删除用户行，定时清理仍可物理删除过期记录；不能只填写 deleted_at 就宣称密文已清空。

`app_user.password_updated_at` 表示当前密码的设置时间：申请注册验证码时先创建待验证用户，此值及密码/密文字段均为 NULL；邮箱验证通过并完成注册时一次填齐，修改或重置密码时更新。待验证用户不能登录或访问数据，不另加账号状态字段。登录成功后将验证密码时读到的这个值写入签名令牌的 passwordUpdatedAt；每次请求都与用户当前值比较，不一致则重新登录。不保存密码历史，也不依赖客户端时钟判断登录是否有效。

该字段采用毫秒精度 timestamptz(3)，API 统一为 UTC ISO 8601（例如 `2026-11-03T09:30:00.123Z`）。新值由 Node 生成，取“服务端当前毫秒时间”和“原值 + 1 毫秒”的较大值；条件 UPDATE 校验原时间。这样同一毫秒内再次改密码或服务器时钟回拨，也不会复用旧值。两次并发修改只有一次能匹配原时间；另一请求重新读取后处理冲突，不无条件覆盖。

密码变更时间与 password_hash、新 salt 和重新加密的快照在同一条 UPDATE 写入，全部旧登录令牌因时间不匹配而失效，无需会话记录或跨表事务。时间戳只做登录失效与并发校验，不参与密钥派生或密文 AAD，客户端无需提前取得服务端将要生成的时间。

## 整份密文同步

首期将主机、身份以及用户选择共享的凭据打成一个客户端 JSON 快照，用密码派生的 dataKey 直接加密后放入 `app_user.ciphertext`。salt、密码验证记录与密文在同一行，避免为了简单连接库拆成多张记录、事件和幂等表。

密文快照上限暂定 1 MiB（不含 12 字节 nonce 和 16 字节 tag），API 请求体上限 1.5 MiB。每次 GET/PUT 同步整份快照，适用于个人连接库；达到上限时明确拒绝，不引入分页或增量日志。代价是一次修改也传输整份内容，并发编辑可能冲突；以后出现实际性能问题再调整。

正常改密码也会更换 dataKey，客户端必须取得最新资料，用新密码与新盐重新加密整份快照，再将密码信息和新密文一起提交。来源快照的 updatedAt 作为条件检查；若其他设备已修改，整次改密失败，重新拉取、合并和加密。邮箱重置则生成新盐并加密空资料。两种操作都拒绝复用当前 salt，避免相同密码重置后得到相同密钥。

写入只带 `expectedUpdatedAt + ciphertext`，expectedUpdatedAt 必须是该编辑所基于的快照一起返回的 updatedAt，不能只刷新时间后覆盖旧内容。一条条件 UPDATE 检查用户 ID、登录对应的密码变更时间和原 updated_at，再保存密文和新的 updated_at。两台设备基于同一份资料保存时，一台成功，另一台收到 409 并重新拉取。客户端保留 base/local/remote，合并不同字段，冲突交由用户处理；endpoint 与 authentication 不拆开合并。删除标记保留在加密快照内，阻止离线旧编辑自动复活。没有服务端 tombstone 表、变更历史、游标或幂等回执表。

待发送密文在客户端保存，同一请求重试不重新加密。服务端确认账号与密码状态仍有效后，若当前完整密文字节已经与请求一致，直接返回当前 updatedAt，不再写入；否则按原更新时间保存或返回冲突。不保存写入编号，也不承诺重放历史 ACK。编辑先可靠保存到本机，SSH 和 UI 不等待网络。

## 不使用多语句事务的一致性安排

| 操作 | 实现与中途失败行为 |
| --- | --- |
| 注册 | 申请验证码时先创建或复用待验证用户。提交时校验并单次消费码，一条带 password_updated_at IS NULL 和原 updated_at 条件的 UPDATE 填齐密码和密文并完成注册。失败重新申请验证码；不恢复已消费记录。成功后普通登录。 |
| 登录 | 验证密码后签发令牌，包含验证时用户的 password_updated_at，不写入登录记录。如果期间密码变化，该令牌会被后续 API 拒绝；新登录不撤销已有登录。 |
| 修改密码 | 客户端暂停该账号编辑和普通上传，取得最新快照并合并本机编辑，用新 salt 与新密码重新加密。一条 UPDATE 检查密码时间和客户端来源快照的 updatedAt，同时替换 salt、password_hash、密文和两个时间。全部旧令牌失效；冲突时重新拉取合并，失败不产生部分改密。 |
| 邮箱重置 | 要求验证码创建时间晚于用户当前 password_updated_at，校验并消费后，用校验时读取的用户 ID、密码变更时间和 updated_at 执行条件 UPDATE，同时替换 salt、password_hash 与加密空快照。旧资料不留在在线表中，旧令牌全部失效。若丢响应，用新密码登录确认；失败则重新申请验证码，不自动重放清空操作。 |
| 同步 | 一条 UPDATE 同时修改快照和 updated_at，WHERE 校验账号、密码变更时间与原 updated_at。更新 0 行则重新读取并判断失效、内容已一致或冲突，不无条件覆盖。 |
| 退出登录 | 客户端停止该账号同步，清除本机令牌与解锁密钥，无服务端接口。已复制的令牌仍可能使用到过期或账号整体失效，不承诺单令牌撤销。 |
| 注销账号 | 一条带当前 password_updated_at 条件的 DELETE 删除用户行；后续请求因找不到用户而失效，遗留验证码按到期时间清理。账号 UUID 不复用。 |

验证码消费与后续用户写入不在一个事务内，因此明确接受“验证码已消费、操作未完成，需要重新申请验证码”的小概率体验成本。没有补偿状态机、分布式锁或新的持久任务表。

## 账号、登录与安全边界

注册邮箱必须验证。验证码 8 位、5 分钟有效，HMAC 后保存。验证时先通过共享限流取得尝试次数，再比较摘要，最后用条件 UPDATE 设置 deleted_at/updated_at；只有一个请求能消费成功并执行业务。deleted_at 为空且未过期才可用，消费或作废后均不可用，到期后物理清理；不另加 used_at 或失效原因字段。

`verification` 通过 user_id 在应用层关联 app_user，邮箱从用户读取，不加外键。注册只允许 app_user.password_updated_at 为 NULL 的待验证用户；重置只允许已注册用户，要求 code.created_at > user.password_updated_at，并明确确认清空资料。复用已有创建时间即可拒绝最近一次注册/改密码之前的码，不保存密码时间快照、用途或额外上下文。最终用户 UPDATE 仍检查本次校验时读取的密码变更时间，避免并发覆盖。详细接口见 [protocol.md](protocol.md#邮箱验证码与中断)。

登录使用固定 HS256 签名的 JWT，有效期 30 天；只包含用户 ID、密码变更时间、签发/到期时间和固定签发者、受众。不保存设备、令牌摘要、会话记录或黑名单，也不引入 refresh token。多端可以同时持有有效令牌，到期后重新登录，普通访问不续期。签名使用 Node 原生 crypto 和部署配置中的 `SECRET_KEY`，与验证码及限流标识的 HMAC 共用，不增加运行时依赖。

每个受保护 API 先校验签名、类型、签发者、受众及有效期，再查询 app_user，要求用户存在、未软删除、已完成注册，且 password_updated_at 与令牌一致。这里省去的是登录记录，仍需查询用户状态。具体格式与校验规则见 [登录令牌](protocol.md#登录令牌与退出)。修改或重置密码使所有旧令牌失效，注销删除用户后所有令牌失效；已通过校验的在途请求仍可能完成，条件写入仍须校验原密码变更时间。

密码修改和注销在请求中再次提供旧密码派生的登录验证材料，不另建 reauth 票据。密码原文及解密材料始终留在客户端，详见 [密码方案](passwords.md)。仅本机私钥不进入快照；服务器 host-key 信任、终端输出、剪贴板和活动会话不同步。

次数上限由 Node 代码判断，verification 不存 attempts；跨 FC 实例的计数复用现有 rate_limit，不能仅放进单个实例内存。邮箱/IP 使用时间窗口计数；每个 codeId 另使用贯穿该码有效期的一个计数 key，Node 仅允许前 5 次，不在窗口切换时归零。数据库只负责并发累计并返回 hit_count，不包含次数阈值。计数失败时拒绝校验，不回退到本机内存；仍然只有三张表，不引入 Redis。

重新申请验证码不能重置邮箱/IP 的累计限制。有效限流计数不得提前软删除或重新创建；到期后统一清理。验证码、loginSecret、token、密文内容和 SSH 信息不写日志。

客户端缓存按 userId 隔离，保存所属 passwordUpdatedAt；只在同一密码时间下自动三方合并。密码时间变化后，其他设备暂停旧队列上传，用新密码登录并下载资料；已同步缓存替换为新资料，未同步编辑单独保留并提示用户手动处理，不能自动合并、重加密或上传。不能直接给旧请求替换新令牌或更新时间。普通改密码和邮箱重置都会换 dataKey，不通过密钥比较区分操作；发起普通改密码的设备只确认已提交快照包含的编辑。密钥不上传或写日志，也不新增密钥指纹字段。离线副本、已取得的旧密钥与旧密文无法远程保证擦除。备份按数据库保留周期处理，不承诺即时擦除所有备份；首期不设计自动恢复系统或删除登记表。

## 运行方式

一个 Node ES modules 服务部署到阿里云 FC，原生 `node:http` / `node:crypto` / `node:test`，唯一直接运行依赖为 `pg`。不引入框架、ORM、Redis、MQ 或独立同步服务。邮件使用原生 fetch 调用阿里云 DirectMail，3 秒超时，失败仅记录事件与 codeId，不记录验证码或收件地址。

PostgreSQL 与 FC 使用同地域 VPC，连接验证 TLS；连接凭据通过部署配置提供。每个实例复用一个小连接池（初始 max=2），实例上限按数据库连接预算设置。不得每请求新建池；不依赖响应返回后仍会执行的 Promise。过期验证码、限流计数，以及创建超过 24 小时仍未激活的用户，由同代码包的定时清理入口删除；用户清理必须带 password_updated_at IS NULL 条件。原生 crypto 使用异步 API，密码验证前限流。

### 本地运行与测试

需要 Node.js 20+、PostgreSQL。先创建独立空数据库并执行 `schema.sql`，不运行旧数据迁移。配置参见 [.env.example](.env.example)，将本机真实值放在未跟踪的 `server/.env` 中；服务端密钥 `SECRET_KEY` 用 `node -e "console.log(require('node:crypto').randomBytes(32).toString('base64url'))"` 生成。不要将生成结果提交到 Git。

```sh
npm ci --prefix server
# DATABASE_URL 由本机环境提供，只对新建的 Pocahontas 数据库执行
psql --dbname "$DATABASE_URL" -v ON_ERROR_STOP=1 -f server/schema.sql
cd server
node --env-file=.env src/main.js
```

`GET /healthz` 只检查进程存活，不查询数据库。监听地址由 `HOST` 指定，未设置时使用 `0.0.0.0`；端口由 `PORT` 指定，未设置时使用 `9000`。只有 loopback PostgreSQL 可设置 `DATABASE_TLS=false`，远程连接始终验证证书。`DATABASE_CA_FILE` 为可选项：默认使用 Node.js 的受信任 CA，只有数据库证书所用 CA 未被信任时才需指定 CA 文件。禁止 URL 中带覆盖 TLS 的参数。真实邮件须先配置 DirectMail 已验证发信域名和地址。

```sh
npm test --prefix server
scripts/test-account.sh
scripts/capture-account-screenshots.sh
```

前两项自动创建、建表并销毁临时 PostgreSQL，使用 Unix socket，不访问现有业务库；需 `initdb` / `pg_ctl` 在 PATH，或设置 `PG_BIN`。测试的内存邮件箱和故障注入接口只在 `test/fixture.js` 的 loopback 服务中存在，部署包不包含它们。

### 阿里云 FC 部署

```sh
scripts/package-server.sh
```

输出 `.build/pocahontas-server.zip`，仅含运行代码、锁定依赖和入口；不含测试、`.env` 或数据库初始化脚本。当前 API 使用 [FC 自定义运行时](https://help.aliyun.com/zh/functioncompute/custom-runtime/)部署：

1. 已创建的 `pocahontas-server` 使用 `custom.debian12`，启动命令为 `npm run start`，平台监听端口为 `9000`。代码默认监听 `0.0.0.0:9000`，不需要额外设置 `HOST` / `PORT`。域名为 `https://pocahontas-api.rockdai.com`，健康接口为 `/healthz`。HTTP 触发器允许 GET、POST、PUT、DELETE，业务鉴权由 Bearer token 完成。代码包仍保留 `fc.handler`，供内置 Node.js 运行时的 v1 HTTP 事件使用。
2. 配置下表中的环境变量。凭据放在部署配置，不放代码包。
3. FC 与数据库使用同地域 VPC；保留访问 DirectMail HTTPS 的网络通路。初始函数内存 512 MiB、超时 30 秒、单实例并发 4；每实例最多 2 个数据库连接。依据数据库连接预算限制最大实例数，给管理与清理连接留余量，压测后再调整。
4. 用同一代码包另建定时函数，入口 `fc.cleanup`，每 15 分钟调用一次，无 HTTP 触发器；删除到期验证码、限流记录和超过 24 小时的未注册用户。保留正在有效期内的计数。
5. 初始化空库后检查健康、真实邮件注册、两台设备同步、改密和重置。默认不记录请求体、授权头、邮件正文或返回密文；不要在平台诊断配置中开启这些内容的采集。

必填环境变量，API 函数和定时清理函数使用同一组配置：

| 变量 | 填写内容 |
| --- | --- |
| `DATABASE_URL` | `postgres://用户名:密码@数据库内网地址:5432/pocahontas`；用户名、密码中的特殊字符需做 URL 编码，不附加查询参数。 |
| `SECRET_KEY` | 随机 32 字节的 Base64URL 编码，无填充；用上面的 Node 命令生成一次，同环境所有实例共用。 |
| `MAIL_SENDER` | DirectMail 中已配置可用的发信地址，例如 `verify@example.com`。 |
| `ACCESS_KEY_ID` | 具有邮件发送权限的阿里云 RAM AccessKey ID。 |
| `ACCESS_KEY_SECRET` | 对应的 AccessKey Secret。 |

以下变量按需配置：

| 变量 | 默认值 / 配置条件 |
| --- | --- |
| `MAIL_REGION` | 默认 `cn-hangzhou`；使用其他邮件地域时修改。 |
| `MAIL_ENDPOINT` | 默认 `https://dm.aliyuncs.com/`；使用其他邮件地域时填写对应 API 地址。 |
| `MAIL_SECURITY_TOKEN` | 使用 STS 临时凭据时填写配套 Token；长期 AccessKey 不填。 |
| `DATABASE_CA_FILE` | 仅数据库 CA 未被 Node.js 信任时填写部署包内可读的 CA 文件路径。 |

当前 API 的 `npm run start` 使用上述默认监听地址和端口；`fc.handler` / `fc.cleanup` 事件入口不使用 `HOST` 或 `PORT`。FC 连接远程数据库时不配置 `DATABASE_TLS=false`。旧的两个服务端密钥配置已由 `SECRET_KEY` 替代；更换该值会使旧登录令牌和未使用验证码失效，并重置限流标识。它不参与客户端 SSH 资料的加解密。

### GitHub Actions 自动部署

[fc-deploy.yaml](../.github/workflows/fc-deploy.yaml) 在 `rockdai/pocahontas` 的 `main` 更新后运行，先执行 server 测试，再使用现有脚本打包并更新已创建的 `pocahontas-server`。部署串行执行，测试或打包失败时不会上传代码。

在仓库 **Settings → Secrets and variables → Actions** 配置：

| 类型 | 名称 | 内容 |
| --- | --- | --- |
| Secret | `ACCESS_KEY_ID` | 部署用 RAM AccessKey ID。 |
| Secret | `ACCESS_KEY_SECRET` | 对应的 AccessKey Secret。 |
| Variable | `FC_REGION` | 函数实际所在地域，例如 `cn-hangzhou`。 |

部署凭据需要 `fc:UpdateFunction` 权限；只具备邮件发送权限的 AccessKey 无法部署。GitHub Secrets 与 FC 环境变量分别配置，不会自动共享；无需把数据库密码、`SECRET_KEY` 或邮件配置复制到 GitHub。

工作流通过阿里云 CLI 调用 [UpdateFunction](https://help.aliyun.com/en/functioncompute/fc/developer-reference/api-fc-2023-03-30-updatefunction)，请求体仅含 `code.zipFile`，不提交环境变量、运行时、入口、网络、内存、超时或触发器配置，也不创建函数、发布版本或调整别名。部署更新 `$LATEST` 的代码，线上触发器需使用该版本。日志只输出函数名、代码校验值和更新状态，不输出 API 返回的完整函数配置。

### App 配置

生成 Xcode 工程后，将 `POCAHONTAS_SERVER_URL` 构建设置设为部署的 HTTPS 根地址（无路径前缀），例如通过 `xcodebuild ... POCAHONTAS_SERVER_URL=https://api.example.com build`。默认留空，App 的本地 SSH 和连接库可用，账号按钮会提示尚未配置。测试仅允许 loopback HTTP；正式环境必须 HTTPS，账号请求不跟随重定向。

Mac 测试包同样接收该配置：`POCAHONTAS_SERVER_URL=https://api.example.com scripts/package-macos-test.sh`，需先提交代码，包内会记录源码版本。

三端从 Saved Connections → Account & Sync 注册、登录、同步及修改密码。邮箱重置会再次确认清空云端资料。旧密码状态下的未同步编辑单独保留，可手动复制到本机库，不自动回传。暂不实现后台推送；本机修改、启动和返回前台时触发同步，也可点 Sync Now。

## 客户端替换与验证

已删除 CloudSync/CKSyncEngine、Apple 账号绑定、iCloud 设置与签名配置，接入 server。Keychain 只做本机存储，不启用 synchronizable。保留本机连接库和冲突合并代码；改用整份快照与已有更新时间，不保留 CloudKit 系统字段、云端游标或迁移入口。

本地验证覆盖注册与重置边界、跨实例限流、并发单次消费、消费后中断、旧码和旧令牌失效、账号隔离、快照并发写与相同密文重试。Swift 与 Node 独立实现的密码派生 / AES-GCM 测试向量一致；两个独立客户端通过真实 Node HTTP 服务和临时 PostgreSQL 验证共享凭据、离线合并、改密 / 重置、旧编辑保留，以及写入成功但响应丢失后的恢复。FC、真实邮件、真机与跨网络验收仍待执行；本地结果不能代替这些验证。
