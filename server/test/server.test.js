import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createDecipheriv, createHmac, randomBytes, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { database, fixture, client } from './helpers.js';
import { fcHandler, httpHandler } from '../src/app.js';
import { createCrypto, digest } from '../src/crypto.js';
import { httpOptionsFromEnv } from '../src/config.js';

let db, f;
before(async () => { db = await database(); f = fixture(db.pool); });
after(async () => { await db?.close(); });
const post = (path, body, token) => f.request('POST', `/v1/auth/${path}`, body, token);
const material = keys => ({ salt: keys.salt, loginSecret: keys.loginSecret, ciphertext: keys.ciphertext });

test('pending users cannot login; code HMAC is stored without plaintext; double consumption loses', async () => {
  const email = 'pending@example.test', keys = client();
  const issued = await post('register/code', { email });
  assert.equal(issued.statusCode, 202);
  const code = f.messages.at(-1).code;
  const stored = await f.store.code(issued.data.codeId);
  assert.equal(stored.hash.length, 32);
  assert.deepEqual(stored.hash, createHmac('sha256', f.secretKey)
    .update(JSON.stringify(['verification-code/v1', issued.data.codeId, stored.user_id, code])).digest());
  assert.equal((await post('login', { email, loginSecret: keys.loginSecret })).statusCode, 401);
  assert.equal((await f.store.byEmail(email)).password_hash, null);
  const fake = (await post('prelogin', { email })).data;
  assert.equal(fake.salt, (await post('prelogin', { email })).data.salt);
  f.tick();
  const body = { codeId: issued.data.codeId, code, ...material(keys) };
  const results = await Promise.all([post('register', body), post('register', body)]);
  assert.deepEqual(results.map(x => x.statusCode).sort(), [201, 400]);
  assert.equal(await f.store.code(issued.data.codeId), undefined);
  const user = await f.store.byEmail(email);
  assert.match(user.password_hash, /^pbkdf2-sha256\$600000\$/);
  assert.ok(!user.password_hash.includes(keys.loginSecret));
});

test('cross-instance attempts persist; consumed codes and ineligible issuance are unusable', async () => {
  const email = 'limits@example.test', keys = client();
  const issued = await post('register/code', { email });
  const code = f.messages.at(-1).code;
  const wrong = code === '00000000' ? '00000001' : '00000000';
  const second = fixture(db.pool, { now: f.now });
  for (let i = 0; i < 5; i++) {
    const instance = i % 2 ? f : second;
    assert.equal((await instance.request('POST', '/v1/auth/register', {
      codeId: issued.data.codeId, code: wrong, ...material(keys),
    })).statusCode, 400);
  }
  assert.equal((await post('register', { codeId: issued.data.codeId, code, ...material(keys) })).statusCode, 429);
  const count = f.messages.length;
  const unknown = await post('password/reset/code', { email: 'absent@example.test' });
  assert.equal(unknown.statusCode, 202);
  assert.equal(f.messages.length, count);
  assert.equal(await f.store.code(unknown.data.codeId), undefined);
});

test('concurrent snapshots have one winner; exact retries do not advance time; users stay isolated', async () => {
  const user = await f.register('snapshots@example.test');
  const other = await f.register('other@example.test');
  const a = user.encrypt([{ name: 'A' }]), b = user.encrypt([{ name: 'B' }]);
  const results = await Promise.all([a, b].map(ciphertext => f.request('PUT', '/v1/vault', {
    expectedUpdatedAt: user.vault.updatedAt, ciphertext,
  }, user.token)));
  assert.deepEqual(results.map(x => x.statusCode).sort(), [200, 409]);
  const remote = (await f.request('GET', '/v1/vault', undefined, user.token)).data;
  const retry = await f.request('PUT', '/v1/vault', {
    expectedUpdatedAt: user.vault.updatedAt, ciphertext: remote.ciphertext,
  }, user.token);
  assert.equal(retry.data.updatedAt, remote.updatedAt);
  assert.ok(remote.updatedAt > user.vault.updatedAt);
  const unrelated = (await f.request('GET', '/v1/vault', undefined, other.token)).data;
  assert.equal(unrelated.ciphertext, other.vault.ciphertext);
  assert.equal((await f.request('PUT', '/v1/vault', { expectedUpdatedAt: remote.updatedAt,
    ciphertext: remote.ciphertext, userId: other.userId }, user.token)).statusCode, 400);
});

test('password changes preserve encrypted data, reject stale sources, and invalidate every old token', async () => {
  const user = await f.register('change@example.test');
  const second = (await post('login', { email: user.email, loginSecret: user.loginSecret })).data;
  const keys = client('a completely different password', [{ name: 'kept' }]);
  const changed = { oldLoginSecret: user.loginSecret, expectedPasswordUpdatedAt: user.vault.passwordUpdatedAt,
    expectedUpdatedAt: user.vault.updatedAt, salt: keys.salt, newLoginSecret: keys.loginSecret, ciphertext: keys.ciphertext };
  const updated = await f.request('PUT', '/v1/vault', { expectedUpdatedAt: user.vault.updatedAt,
    ciphertext: user.encrypt([{ name: 'kept' }]) }, user.token);
  assert.equal((await f.request('PUT', '/v1/auth/password', changed, user.token)).statusCode, 409);
  const before = await f.store.user(user.userId);
  assert.equal(before.salt.toString('base64url'), user.salt);
  changed.expectedUpdatedAt = updated.data.updatedAt;
  assert.equal((await f.request('PUT', '/v1/auth/password', changed, user.token)).statusCode, 200);
  for (const token of [user.token, second.token]) assert.equal((await f.request('GET', '/v1/vault', undefined, token)).statusCode, 401);
  assert.equal((await post('login', { email: user.email, loginSecret: user.loginSecret })).statusCode, 401);
  const signed = await post('login', { email: user.email, loginSecret: keys.loginSecret });
  assert.equal(signed.statusCode, 200);
  const bytes = Buffer.from(signed.data.vault.ciphertext, 'base64url');
  const decipher = createDecipheriv('aes-256-gcm', keys.key, bytes.subarray(0, 12));
  decipher.setAAD(Buffer.from('pocahontas/snapshot/v1\n'));
  decipher.setAuthTag(bytes.subarray(-16));
  const plain = Buffer.concat([decipher.update(bytes.subarray(12, -16)), decipher.final()]);
  assert.equal(JSON.parse(plain).records[0].name, 'kept');
});

test('password reset requires fresh email code and deletion consent; same salt and old codes fail', async () => {
  const user = await f.register('reset@example.test');
  f.tick();
  const issued = await post('password/reset/code', { email: user.email });
  const code = f.messages.at(-1).code, keys = client();
  const body = { codeId: issued.data.codeId, code, confirmDelete: true, ...material(keys) };
  assert.equal((await post('password/reset', { ...body, confirmDelete: false })).statusCode, 400);
  assert.equal((await post('password/reset', { ...body, salt: user.salt })).statusCode, 400);
  assert.equal((await post('password/reset', body)).statusCode, 200);
  assert.equal((await post('password/reset', body)).statusCode, 400);
  assert.equal((await f.request('GET', '/v1/vault', undefined, user.token)).statusCode, 401);
  assert.equal((await post('login', { email: user.email, loginSecret: keys.loginSecret })).statusCode, 200);
  const saved = await f.store.user(user.userId);
  assert.equal(saved.ciphertext.toString('base64url'), keys.ciphertext);
});

test('register and password-change invalidate earlier codes; a crash after consumption cannot replay', async () => {
  const email = 'old-code@example.test', keys = client();
  const first = await post('register/code', { email });
  const oldCode = f.messages.at(-1).code;
  const second = await post('register/code', { email });
  f.tick();
  await post('register', { codeId: second.data.codeId, code: f.messages.at(-1).code, ...material(keys) });
  assert.equal((await post('password/reset', { codeId: first.data.codeId, code: oldCode,
    confirmDelete: true, ...material(client()) })).statusCode, 400);
  const interrupted = fixture(db.pool, { now: f.now });
  const issued = await interrupted.request('POST', '/v1/auth/register/code', { email: 'crash@example.test' });
  interrupted.store.setPassword = async () => { throw new Error('database outage'); };
  const body = { codeId: issued.data.codeId, code: interrupted.messages.at(-1).code, ...material(client()) };
  assert.equal((await interrupted.request('POST', '/v1/auth/register', body)).statusCode, 503);
  assert.equal((await interrupted.request('POST', '/v1/auth/register', body)).statusCode, 400);
  assert.equal((await f.store.byEmail('crash@example.test')).password_updated_at, null);
});

test('JWT rejects tampering, wrong audience, expiry and deletion, without disclosing internal data', async () => {
  const user = await f.register('jwt@example.test');
  assert.equal((await f.request('GET', '/v1/me', undefined, user.token + 'x')).statusCode, 401);
  const parts = user.token.split('.');
  assert.equal(parts[2], createHmac('sha256', f.secretKey)
    .update(parts.slice(0, 2).join('.')).digest('base64url'));
  const payload = JSON.parse(Buffer.from(parts[1], 'base64url'));
  payload.aud = 'another-service';
  parts[1] = Buffer.from(JSON.stringify(payload)).toString('base64url');
  parts[2] = digest(f.secretKey, parts.slice(0, 2).join('.')).toString('base64url');
  assert.equal((await f.request('GET', '/v1/me', undefined, parts.join('.'))).statusCode, 401);
  const crypto = createCrypto(f);
  assert.throws(() => crypto.verify(user.token, f.now() + 31 * 86400000));
  assert.equal((await f.request('DELETE', '/v1/me', { loginSecret: user.loginSecret }, user.token)).statusCode, 204);
  assert.equal((await f.request('GET', '/v1/me', undefined, user.token)).statusCode, 401);
  assert.equal(await f.store.user(user.userId), undefined);
  assert.ok(!JSON.stringify(f.logs).includes(user.loginSecret));
});

test('expired and soft-deleted records cannot bypass checks; cleanup retains live limits', async () => {
  const user = await f.register('cleanup@example.test');
  await db.pool.query('UPDATE app_user SET deleted_at = $1 WHERE id = $2', [new Date(f.now()), user.userId]);
  assert.equal((await f.request('GET', '/v1/me', undefined, user.token)).statusCode, 401);
  const email = 'expires@example.test';
  const code = await post('register/code', { email });
  const value = f.messages.at(-1).code;
  f.tick(300001);
  assert.equal((await post('register', { codeId: code.data.codeId, code: value, ...material(client()) })).statusCode, 400);
  const key = randomBytes(32);
  await f.store.hit(key, new Date(f.now()), new Date(f.now() + 600000));
  await f.service.cleanup();
  assert.equal(await f.store.code(code.data.codeId), undefined);
  assert.equal((await db.pool.query('SELECT hit_count FROM rate_limit WHERE key = $1', [key])).rows[0].hit_count, 1);
  const failed = fixture({ async query() { throw new Error('secret database hostname'); } });
  const result = await failed.request('POST', '/v1/auth/prelogin', { email });
  assert.equal(result.statusCode, 503);
  assert.ok(!result.body.includes('hostname'));
});

test('HTTP and FC adapters enforce input size, JSON, header normalization and source IP', async () => {
  const server = createServer(httpHandler(f.app)).listen(0, '127.0.0.1');
  await once(server, 'listening');
  try {
    const base = `http://127.0.0.1:${server.address().port}`;
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
    const malformed = await fetch(`${base}/v1/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{' });
    assert.equal(malformed.status, 400);
    assert.equal(malformed.headers.get('cache-control'), 'no-store');
    const large = await fetch(`${base}/v1/auth/login`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: 'x'.repeat(1600000) });
    assert.equal(large.status, 413);
    const invoke = fcHandler(f.app);
    const result = await invoke(Buffer.from(JSON.stringify({ version: 'v1', body: Buffer.from('{"email":"fc@example.test"}').toString('base64'),
      isBase64Encoded: true, headers: { 'Content-Type': 'application/json' },
      requestContext: { http: { method: 'POST', path: '/v1/auth/prelogin', sourceIp: '192.0.2.1' } } })));
    assert.equal(result.statusCode, 200);
    assert.equal(JSON.parse(result.body).iterations, 600000);
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
});

test('FC HTTP listener accepts health checks on all IPv4 interfaces and rejects invalid ports', async () => {
  const fc = { FC_FUNCTION_NAME: 'pocahontas-server', FC_CUSTOM_LISTEN_PORT: '0' };
  const server = createServer(httpHandler(f.app)).listen(httpOptionsFromEnv(fc));
  await once(server, 'listening');
  try {
    assert.equal(server.address().address, '0.0.0.0');
    const response = await fetch(`http://127.0.0.1:${server.address().port}/healthz`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true });
  } finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
  for (const port of ['invalid', '-1', '65536']) {
    assert.throws(() => createServer().listen(httpOptionsFromEnv({ ...fc, FC_CUSTOM_LISTEN_PORT: port })),
      { code: 'ERR_SOCKET_BAD_PORT' });
  }
});
