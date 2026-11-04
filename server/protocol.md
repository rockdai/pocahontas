# Pocahontas server API v1

状态：Node.js API 与 Apple 客户端已实现，本地集成测试通过，实际 FC 联调待部署。HTTPS + JSON UTF-8；API UUID 小写，二进制使用无填充 Base64URL，用户更新时间使用 UTC ISO 8601 毫秒字符串。原生客户端不需要通配 CORS。除登录/注册/邮箱验证与重置入口外，使用 `Authorization: Bearer <token>`；敏感响应设置 `Cache-Control: no-store`。

所有表的普通读取与条件写入均过滤 `deleted_at IS NULL`；鉴权校验签名令牌并读取 app_user 的当前状态。Node 在每次写入维护 updated_at，插入时同时填写 created_at。所有 app_user UPDATE 都检查原 updated_at，新值由 Node 取 max(当前服务端毫秒时间, 原值 + 1 毫秒)，详见 [时间规则](README.md#通用字段与密码变更时间)。邮箱重置和账号注销仍按实际清空规则执行，不以软删除标记替代清空密文。

## 基本接口

| 方法与路径 | 行为 |
| --- | --- |
| `GET /healthz` | 存活检查，不回显配置。 |
| `POST /v1/auth/register/code` | `{email}` → `202 {codeId}`。创建或复用待验证用户，为其发送验证码；已有正式账号则返回相同格式的无效 codeId，不改账号。 |
| `POST /v1/auth/password/reset/code` | `{email}` → `202 {codeId}`。仅向已完成注册的用户发送验证码；其他情况返回相同格式的无效 codeId。 |
| `POST /v1/auth/register` | `{codeId,code,salt,loginSecret,ciphertext}` → `201`。校验并消费验证码，用一条条件 UPDATE 为其关联的待验证用户写入完整密码与密文数据，完成注册。随后正常登录。 |
| `POST /v1/auth/prelogin` | `{email}` → `{kdfVersion:1,iterations:600000,salt}`。未知邮箱和待验证用户返回稳定伪造盐和同样的参数。 |
| `POST /v1/auth/login` | `{email,loginSecret}` → `{token,expiresAt,userId,vault}`。验证密码后签发 JWT，返回 vault 供本机解密；不写登录记录，也不撤销其他登录。 |
| `PUT /v1/auth/password` | `{oldLoginSecret,expectedPasswordUpdatedAt,expectedUpdatedAt,salt,newLoginSecret,ciphertext}`。客户端用新密码和新盐重新加密来源快照；server 验证旧密码，单条 UPDATE 校验来源快照的两个时间，同时更新密码信息与密文。成功后重新登录。 |
| `POST /v1/auth/password/reset` | `{codeId,code,confirmDelete:true,salt,loginSecret,ciphertext}`。客户端用新密码和新盐加密空资料；server 校验并消费验证码，用本次校验读取的用户 ID、密码变更时间和 updated_at 执行条件 UPDATE，替换密码信息与密文。成功后用新密码登录。 |
| `GET /v1/me` | 当前用户基本资料。 |
| `DELETE /v1/me` | body 携带 `loginSecret` 再次验证，带当前 password_updated_at 条件删除用户行，`204`。后续请求因用户不存在而失效；遗留验证码自然到期清理。 |
| `GET /v1/vault` | 当前整份密文快照及解密所需元数据。 |
| `PUT /v1/vault` | `{expectedUpdatedAt,ciphertext}` → `{updatedAt}`。复用上次读取快照的更新时间保存完整快照；冲突 `409`。 |

密码、注册和重置流程见 [passwords.md](passwords.md)。不提供 refresh、reauth、单记录 CRUD、增量 changes、历史版本或恢复密钥接口。

`app_user.password_hash` 仅为 server 内部存储字段，格式包含算法、次数、随机盐和验证值。客户端仍提交 loginSecret；注册、修改或重置密码时由 server 生成新的完整记录，登录时解析并校验。所有 API 均不接受或返回 password_hash/passwordHash，也不将其放入令牌或日志。

## 登录令牌与退出

首期仅使用服务端签发的 HS256 JWT，通过 `Authorization: Bearer` 传递。采用标准三段 JWS compact 格式：`base64url(header).base64url(payload).base64url(HMAC-SHA256(signingKey,前两段及中间的点))`；二进制编码不带填充。header 固定为 `{"alg":"HS256","typ":"JWT"}`，签发和验证均使用该固定 header 的编码，不根据请求选择算法或密钥，也不接受其他 header 字段。Node 使用原生 `createHmac` 与 `timingSafeEqual`；按 [RFC 7518 §3.2](https://www.rfc-editor.org/rfc/rfc7518.html#section-3.2) 和 [RFC 8725](https://www.rfc-editor.org/rfc/rfc8725.html) 固定算法、检查签名及受众。

payload 仅包含：

| 字段 | 值 |
| --- | --- |
| iss | 固定 `pocahontas-server`。 |
| aud | 固定 `pocahontas-api`。 |
| sub | 通过密码验证的用户 UUID。 |
| passwordUpdatedAt | 验证密码时读到的 app_user.password_updated_at，UTC ISO 8601 毫秒字符串。 |
| iat | 服务端签发时的整数 Unix 秒。 |
| exp | iat + 2,592,000 秒，即 30 天；响应 expiresAt 由此换算。 |

签名密钥为部署配置提供的独立随机 32 字节秘密，所有同环境 FC 实例共用，不与验证码 HMAC 密钥复用，不下发客户端、不写数据库。测试/生产使用不同密钥；配置缺失拒绝启动，不临时随机生成。整体更换密钥会使旧令牌失效，首期不设计密钥历史表或轮换服务。令牌仅认证、不加密，不能放邮箱、密码材料、密钥或 SSH 信息。

验证顺序固定：限制令牌最多 4 KiB、恰好三段且为规范 Base64URL；检查固定 header 与 32 字节签名，以恒定时间比较 HMAC；再解析 payload，校验字段和类型、iss/aud、UUID、合法的毫秒时间字符串，以及安全整数 iat/exp。要求 exp = iat + 2,592,000 且当前时间严格小于 exp；iat 最多允许比服务端当前时间快 60 秒。随后按 sub 查询用户，要求存在、未软删除、password_updated_at 非空且与令牌相等。校验失败统一 401；用户状态读取失败返回 503，不跳过查询。请求体中的 userId 不能覆盖 sub。

签发时必须使用实际验证密码的那份用户记录及 password_updated_at，不能验证旧密码后重新读取新时间再签发。若签发期间密码已变化，这枚令牌会因时间不匹配而被后续请求拒绝。每次成功登录都可签发令牌，已有有效令牌继续可用；没有设备记录、单令牌撤销或 refresh token，普通访问不延长有效期。

退出是本机操作：停止该账号同步，清除本机令牌与解锁密钥。不提供 logout 或设备管理 API，也不记录令牌黑名单。退出不会让已复制的令牌立即在服务端失效；它持续有效至到期、密码修改/重置或用户删除。修改密码和重置会更新 password_updated_at；注销删除用户。三者都会让后续请求的旧令牌校验失败，已通过校验的在途请求可能完成，写操作仍带原密码变更时间条件。

## 邮箱验证码与中断

验证码通过 user_id 关联 app_user，邮箱只存在 app_user.email 中；这是应用层关联，不添加外键。申请注册验证码时，先用普通 INSERT 创建只含 ID、邮箱和通用时间字段的待验证用户；遇到邮箱唯一键冲突则读取已有用户，绝不覆盖其数据。已有待验证用户可重新申请验证码，不要求知道最初申请者的任何秘密；已有正式账号不能走注册流程。

`app_user.password_updated_at IS NULL` 表示尚未完成邮箱验证与密码设置，此时 salt、password_hash 与 ciphertext 均为 NULL，不能登录、取得登录令牌或访问数据。注册成功时一条 UPDATE 填齐所有字段并设置 password_updated_at；不存在“能登录但尚未验证”的账号。不增加独立 status 或 email_verified_at 字段。邮箱规范化见 [passwords.md](passwords.md#用户流程)。

验证码只负责验证所关联用户的邮箱，不保存发码时的账号快照。注册要求用户当前 password_updated_at 为 NULL；重置要求其非空、code.created_at > user.password_updated_at，并且 confirmDelete:true。这样注册完成或修改/重置密码后，之前创建的码不能继续用于重置；注销重建后 user_id 也不同。两个时间都由服务端生成；边界相等时保守拒绝，重新申请即可。FC 实例需保持系统时间同步，与验证码和令牌的到期判断使用同一时间基础。

不再存 channel、destination/email、purpose、context、attempts 或 used_at；也不提供独立 verify 接口或中间票据。申请接口仅接收邮箱，不接受客户端指定 user_id 或账号状态；最终业务目标只能来自验证码关联的用户。

申请先执行邮箱/IP 限流，再由 Node 安全随机生成 8 位数字验证码（保留前导零），5 分钟有效。verification.hash 使用服务端秘密做 HMAC-SHA256，输入为固定顺序 JSON 数组 `["verification-code/v1",codeId,userId,code]` 的 UTF-8 字节；不保存或记录验证码明文，秘密不放在数据库里。验证码需关联用户、单次有效、到期失效并限制猜测，参见 [OWASP 密码重置指南](https://cheatsheetseries.owasp.org/cheatsheets/Forgot_Password_Cheat_Sheet.html#general-security-practices)。

只有符合对应入口用户状态、且用户未软删除时才创建验证码并发送。不存在、状态不符或已软删除时返回相同格式的随机 codeId 与 202，控制响应时序，避免泄露邮箱是否注册。插入验证码后在当前请求内等待邮件发送调用结束；202 仅表示申请受理，不承诺送达。发送失败使用相同响应并记录不含敏感信息的运行错误，用户可在限流允许后重试。不存 delivered_at，不依赖响应之后的后台 Promise。

最终注册/重置先验证请求形状（重置必须 confirmDelete 为 true），再按以下顺序处理：

1. 查询验证码及其关联用户，检查两者 deleted_at 均为 NULL、验证码未到期；注册要求用户尚未设置密码，重置要求用户已设置密码、验证码创建时间晚于该时间，且提交的新 salt 与原盐不同。
2. 通过共享 rate_limit 计数取得本次校验次数，Node 只允许第 1–5 次继续。外层邮箱/IP 限流仍执行，重新申请验证码不归零这些累计限制。成功取得次数后，用恒定时间比较验证码 HMAC。
3. 比较正确后，以条件 UPDATE 设置验证码的 deleted_at 与 updated_at；重新检查未消费、未到期。只有更新成功的一个请求能继续，失败不能进入用户写入。
4. 按关联的 user_id 更新用户。注册条件要求 password_updated_at IS NULL；重置条件要求它等于第 1 步从 app_user 读取的非空时间，仅在本次请求内保留该值。两者都要求用户未删除、updated_at 等于第 1 步读到的原值，且一次写入完整密码和库字段并推进 updated_at。条件不匹配、错误码、过期、已消费或用户不存在，均返回 `400 invalid_code`。用户状态检查也必须放进最终 UPDATE，不能只依赖前面一次读取；消费之后若有其他用户写入导致冲突，同样重新申请验证码。

限流规则由 Node 决定，计数由现有 rate_limit 共享保存。单码 key 是服务端 HMAC 对 `["verification-attempt",codeId]` 的摘要，expires_at 与验证码一致；不按分钟切桶，避免同一个码跨时间窗口重新获得次数。不同 FC 实例或重启后的请求使用同一个 key。以下语句只累计并返回 hit_count；Node 判断 `hit_count <= 5` 才允许继续，不能先 SELECT 再无条件写回。计数不可用或没有返回行时拒绝继续，不退回内存计数。有效计数不得提前删除或重新创建。

```sql
INSERT INTO rate_limit (created_at, updated_at, deleted_at, key, hit_count, expires_at)
VALUES ($2, $2, NULL, $1, 1, $3)
ON CONFLICT (key) DO UPDATE
SET hit_count = rate_limit.hit_count + 1, updated_at = $2
WHERE rate_limit.deleted_at IS NULL AND rate_limit.expires_at > $2
RETURNING hit_count;
```

```sql
UPDATE verification
SET deleted_at = $3, updated_at = $3
WHERE id = $1 AND user_id = $2
  AND deleted_at IS NULL AND expires_at > $3
RETURNING user_id;
```

消费语句的 $2 来自已校验记录的 user_id，$3 为执行时的服务端当前时间。它只能在取得次数额度、核对用户状态且比对验证码成功后执行。deleted_at 同时表示消费或作废，首期无需区分原因，也绝不恢复为 NULL；过期后统一物理清理。

创建待验证用户、写验证码、累计次数、消费码和最终用户写入各自执行，不使用跨表事务。中途失败可重新申请验证码；已消费记录不恢复，不自动重放清空操作。完成用户 UPDATE 后丢响应，可尝试新密码登录。待验证用户 24 小时后可按 `password_updated_at IS NULL` 条件清理；与验证并发时，用户 UPDATE 或清理只有一方能匹配，验证失败则重新申请。无用户的验证码不能通过校验，按原到期时间清理，不为此引入级联删除。

客户端自行生成随机 salt，从密码派生 dataKey 并加密初始资料，无需提前获取 userId 或申请其他编号，详见下文。

## 密码修改的条件写入

普通改密码必须重新加密整份资料。客户端暂停本机资料编辑和普通快照上传，等待在途保存结束，读取最新快照及其两个时间；解密并合并当前密码状态下的本机编辑后，用新 salt 和新密码派生 dataKey 加密、自检。请求的 expectedUpdatedAt 必须对应这份来源快照；不能只获取一个新时间给旧内容重试。

server 检查当前登录、expectedPasswordUpdatedAt 与用户密码时间一致，再验证旧 loginSecret；新 salt 必须为 32 字节且与当前盐不同。由新登录材料生成 password_hash，按时间规则计算两个新时间后执行：

```sql
UPDATE app_user
SET salt = $1, password_hash = $2, ciphertext = $3,
    password_updated_at = $4, updated_at = $5
WHERE id = $6 AND deleted_at IS NULL
  AND password_updated_at = $7 AND updated_at = $8
RETURNING password_updated_at, updated_at;
```

参数依次为新盐、server 生成的新 password_hash、客户端提交的新密文、新密码时间、新更新时间、已认证用户 ID、验证旧密码时的密码时间、客户端提交的 expectedUpdatedAt。最后一个参数不能改用 server 接收请求时读到的更新时间，否则会把客户端重加密期间其他设备的修改覆盖掉。整条语句匹配后才一起替换密码信息和资料，不使用多语句事务。

更新 0 行时重新核对账号：账号无效或密码时间变化返回 401；仅来源快照时间变化返回 409 sync_conflict，所有密码及密文字段保持原值。客户端必须重新下载、合并并加密。成功后旧令牌全部失效，用新密码登录确认；响应丢失也先尝试新密码，不自动重放操作或删除待确认编辑。server 不能解密并证明新旧资料内容一致，该保证由官方客户端的解密、合并和提交前自检完成。

## 快照与并发

`GET /v1/vault` 返回：

```json
{
  "userId": "11111111-1111-4111-8111-111111111111",
  "passwordUpdatedAt": "2026-11-03T09:30:00.123Z",
  "updatedAt": "2026-11-03T09:31:00.456Z",
  "salt": "…",
  "ciphertext": "…"
}
```

已完成注册的用户行必须包含完整密码信息和密文。Node 在注册的条件 UPDATE 中一次填齐字段，登录/鉴权先拒绝 password_updated_at 为 NULL 的待验证用户，再验证必要字段、长度与关系；不能把待验证用户的 NULL 资料当作正常空库返回。salt、密文及两个时间从同一份用户记录返回，客户端根据密码和该 salt 派生 dataKey 后解密。解密失败时拒绝同步并保留本机编辑，不能当成空库回写。server 不解密内容，也不能验证客户端提交的密文与密码是否相符，官方客户端提交前须本机解密自检。

客户端将 updatedAt 与该次下载的快照一起保存。提交 expectedUpdatedAt 表示编辑基于那份资料，不能只取最新时间给旧密文重新提交。server 先查询并核对账号、密码时间；当前密文与请求完全相同时直接返回当前 updatedAt，不更新行，否则用以下语句只更新 `app_user` 一行：

```sql
UPDATE app_user
SET ciphertext = $1, updated_at = $2
WHERE id = $3 AND deleted_at IS NULL AND password_updated_at = $4
  AND updated_at = $5
RETURNING updated_at;
```

参数依次为新密文、Node 生成的新更新时间、已认证用户 ID、令牌对应的密码变更时间、请求 expectedUpdatedAt。只有请求时间与 server 读取的行时间一致时才尝试写入；新时间为 max(Date.now(), 原更新时间 + 1 毫秒)，不采用客户端提供的当前时间。userId/passwordUpdatedAt 来自已验签并与当前用户状态核对的令牌，不能信任请求体自行声明。

条件不匹配时重新读取用户：不存在、已软删除或密码时间变化返回 `401`；仍有效且当前密文与请求完全一致则返回当前 updatedAt；其余返回 `409 sync_conflict`，客户端重新获取并合并。不要先读后无条件覆盖，也不使用显式行锁。PostgreSQL 在并发 UPDATE 时会重新检查 WHERE 条件，见 [Read Committed 说明](https://www.postgresql.org/docs/current/transaction-iso.html#XACT-READ-COMMITTED)。复用用户行的时间意味着其他用户资料修改也可能产生同步冲突；不为此增加专用字段。

如果写入成功但响应丢失，按上述完整密文字节比较识别当前内容已经一致，不需要写入编号或历史回执。若当前已有其他不同内容，返回冲突并重新读取/合并。客户端保留 base 与本机待提交快照；同一请求重试不重新生成密文。每个账号在一台设备上只发送一个快照写请求，ACK 只确认对应的本机编辑，不能清除随后产生的编辑。

缓存及待上传内容按 userId 隔离，并保留其 passwordUpdatedAt。仅在同一密码时间下自动三方合并。密码时间改变时，其他设备暂停旧队列上传，用新密码登录、下载并解密当前资料；已同步缓存以新资料替换，未同步编辑单独保留并提示用户手动处理，不能自动合并、重加密或上传。普通改密码和邮箱重置都会换 dataKey，不依赖比较密钥区分操作。不能给旧请求直接替换新令牌或 expectedUpdatedAt。发起普通改密码的设备只确认本次已提交快照包含的编辑；其他未同步编辑不能静默删除。

删除标记在加密 JSON 的记录中保留，已删除记录只含 ID 与删除状态。客户端三方合并时删除优先于旧编辑，恢复必须新建 ID；冲突需要审阅，不静默组合 endpoint 和认证方式。共享凭据及引用在同一快照提交，不需要两个上传通道或跨记录事务。

快照最大 1 MiB 密文 + 28 字节 nonce/tag；请求体上限 1.5 MiB。超限返回 413。没有分页游标与增量事件。

## 加密快照格式

`ciphertext` 在数据库保存 `nonce[12] || encryptedBytes || tag[16]` 拼接后的二进制数据，在 API 中使用无填充 Base64URL 编码；encryptedBytes 是 AES-256-GCM 的原始加密输出。AES-256-GCM 使用标准平台密码库，每次新加密生成新的随机 nonce。dataKey 由密码和 salt 派生，见 [密码派生与数据加密](passwords.md#密码派生与数据加密)。

整份快照直接使用 dataKey 加密，AAD 为固定 UTF-8 格式标识，末尾包含 LF：

```text
pocahontas/snapshot/v1\n
```

注册、修改密码和邮箱重置都使用客户端新生成的随机 salt；改密码和重置不能复用当前盐。账号归属由 server 的登录校验与用户行限定；userId、updatedAt、passwordUpdatedAt 均不参与 AAD，客户端可在注册/重置前准备初始密文。更新时间只用于在线并发检查；加密认证保护内容完整性，不单独证明某份密文是最新内容。plaintext 是 `{schemaVersion:1,records:[...]}`；schemaVersion 是 JSON 格式标识，不是资料修改次数。记录按稳定随机 ID 表示 host、identity、credential，引用用显式 type/id 表示，不采用 Swift 枚举自动编码布局。仅本机秘密不放进快照。未知 schema 保留原始密文并提示升级，不能回写空库。

普通改密码时客户端用新派生的 dataKey 重新加密完整资料；邮箱重置则用新派生的 dataKey 加密空资料。server 用同一条条件 UPDATE 替换 salt、password_hash 和 ciphertext，并更新密码时间与行更新时间。server 只能校验协议形状及新盐与原值不同，不能证明加密内容为空；官方客户端必须按相应流程准备和自检快照，“清空”指旧云端密文已被替换。

### 解密后的 records

JSON 使用 camelCase；ID 与 revision 为随机 UUID，编码小写，读取按 UUID 比较。host 和 identity 的 ID 在同一库内唯一，类型不能变更。revision 只用于客户端确认某次本地编辑，不是数据库版本字段。

| type | 字段 |
| --- | --- |
| `host` | `id`、`revision`、`name`、`tags:[]`、`binding:{host,port,username,authentication}`。 |
| `identity` | `id`、`revision`、`name`、`tags:[]`、`identity:{publicKey,fingerprint,secret,requiresPassphrase}`。 |
| `credential` | `id` 等于凭据引用的 revision；`credential:{reference,value}`，value 为密码或 OpenSSH 私钥字符串。 |

authentication 为 `{type:"password",reference?:{...}}` 或 `{type:"identity",id:"身份 UUID"}`；缺少密码引用表示连接时询问。凭据引用为 `{ownerScope:"账号 UUID",id:"逻辑 UUID",revision:"不可变内容 UUID",kind:"password"或"privateKey",storage:"device"或"account"}`。identity.secret 使用同一引用结构。`device` 引用只传递元数据，不产生 credential 项；`account` 引用必须在本快照中找到完全一致的 credential 项，值不可为空且最多 64 KiB。共享项只在整份 AES-GCM 密文内传输，不能作为明文 API 参数。

删除主机或身份时仅保留 `{type,id,deleted:true}`，不上传旧名称、端点或公钥；凭据修订暂时保留，以支持离线设备的旧引用。未知 schema 或记录 type 不能用空库替代。Apple 的编码/校验入口是 `VaultSnapshot`，各端按此格式互通，不依赖 Swift 自动枚举编码。

## 输入和错误

邮箱上限 254 bytes；登录仅接收 email/loginSecret，不采集安装 ID、设备名称或平台。时间必须为合法的 UTC ISO 8601 毫秒字符串，二进制为规范 Base64URL。Node 严格拒绝额外字段，不用数据库 CHECK 承担这些校验。

错误为 `{error:{code,message,requestId}}`：400 输入错误，401 令牌/认证失效，404 不存在，409 并发修改冲突，413 超出大小限制，429 频率限制，503 暂时不可用。错误不回显密码材料、验证码、token、密文或 SQL。
