import { randomInt, randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { codeHash, createCrypto, digest, equal, ITERATIONS } from './crypto.js';
import { binary, email, encryptedInput, fail, iso, MAX_CIPHERTEXT, nextTime, object, timestamp, uuid } from './validation.js';

export function createService({ store, secretKey, mailer, now = Date.now,
  logger = () => {}, issuanceDelay = 3200, maxKDF = 4 }) {
  const crypto = createCrypto({ secretKey, maxKDF });
  async function hit(parts, limit, expires, time = now()) {
    const row = await store.hit(digest(secretKey, JSON.stringify(parts)), new Date(time), new Date(expires));
    if (!row) fail(503, 'unavailable');
    if (row.hit_count > limit) fail(429, 'rate_limited');
  }
  async function limit(kind, identity, maximum, window = 900000) {
    const time = now(), bucket = Math.floor(time / window);
    await hit([kind, identity, bucket], maximum, (bucket + 1) * window, time);
  }
  function complete(user) {
    return user && user.password_updated_at && user.password_hash
      && Buffer.isBuffer(user.salt) && user.salt.length === 32
      && Buffer.isBuffer(user.ciphertext) && user.ciphertext.length >= 29;
  }
  function vault(user) {
    return { userId: user.id, passwordUpdatedAt: iso(user.password_updated_at),
      updatedAt: iso(user.updated_at), salt: user.salt.toString('base64url'),
      ciphertext: user.ciphertext.toString('base64url') };
  }
  async function authenticate(authorization) {
    if (typeof authorization !== 'string' || !authorization.startsWith('Bearer ')) fail(401, 'unauthorized');
    const token = crypto.verify(authorization.slice(7), now());
    const user = await store.user(token.sub);
    if (!complete(user) || iso(user.password_updated_at) !== token.passwordUpdatedAt) fail(401, 'unauthorized');
    return user;
  }
  async function issue(body, reset) {
    object(body, ['email']);
    const address = email(body.email);
    await limit('send-email', address, 5);
    const start = Date.now(), id = randomUUID();
    try {
      const user = reset ? await store.byEmail(address) : await store.pendingUser(address, new Date(now()));
      if (!user || Boolean(user.password_updated_at) !== reset) return { codeId: id };
      const code = String(randomInt(100000000)).padStart(8, '0');
      const created = now();
      await store.addCode(id, user.id, codeHash(secretKey, id, user.id, code),
        new Date(created), new Date(created + 300000));
      try { await mailer.sendCode(address, code); }
      catch { logger({ event: 'mail_failed', codeId: id }); }
      return { codeId: id };
    } finally { await delay(Math.max(0, issuanceDelay - (Date.now() - start))); }
  }
  async function redeem(body, reset) {
    object(body, ['codeId', 'code', 'salt', 'loginSecret', 'ciphertext', ...(reset ? ['confirmDelete'] : [])]);
    const id = uuid(body.codeId);
    if (!/^\d{8}$/.test(body.code) || typeof body.code !== 'string' || (reset && body.confirmDelete !== true)) fail(400, 'invalid_input');
    const input = encryptedInput(body);
    const code = await store.code(id);
    const user = code && await store.user(code.user_id);
    const time = now();
    if (!user || !code || new Date(code.expires_at).getTime() <= time
        || Boolean(user.password_updated_at) !== reset
        || (reset && (new Date(code.created_at) <= new Date(user.password_updated_at) || equal(input.salt, user.salt))))
      fail(400, 'invalid_code');
    await limit('verify-email', user.email, 30);
    await hit(['verification-attempt', id], 5, new Date(code.expires_at).getTime(), time);
    if (!equal(code.hash, codeHash(secretKey, id, user.id, body.code))) fail(400, 'invalid_code');
    const passwordHash = await crypto.passwordHash(input.loginSecret);
    if (!await store.consume(id, user.id, new Date(now()))) fail(400, 'invalid_code');
    const changed = nextTime(user.password_updated_at ?? user.created_at, now());
    const result = await store.setPassword(user, { ...input, passwordHash }, changed, nextTime(user.updated_at, now()));
    if (!result) fail(400, 'invalid_code');
    return { registered: !reset };
  }
  async function dispatch({ method, path, body, authorization, ip }) {
    if (method === 'GET' && path === '/healthz') return { status: 200, data: { ok: true } };
    await limit('request-ip', ip, 300, 60000);
    const route = `${method} ${path}`;
    if (route === 'POST /v1/auth/register/code' || route === 'POST /v1/auth/password/reset/code') {
      await limit('send-ip', ip, 30);
      return { status: 202, data: await issue(body, path.includes('/reset/')) };
    }
    if (route === 'POST /v1/auth/register' || route === 'POST /v1/auth/password/reset') {
      await limit('verify-ip', ip, 60);
      const reset = path.endsWith('/reset');
      return { status: reset ? 200 : 201, data: await redeem(body, reset) };
    }
    if (route === 'POST /v1/auth/prelogin') {
      object(body, ['email']);
      const address = email(body.email);
      await limit('prelogin-email', address, 30);
      const user = await store.byEmail(address);
      return { status: 200, data: { kdfVersion: 1, iterations: ITERATIONS,
        salt: (complete(user) ? user.salt : crypto.fakeSalt(address)).toString('base64url') } };
    }
    if (route === 'POST /v1/auth/login') {
      object(body, ['email', 'loginSecret']);
      const address = email(body.email), secret = binary(body.loginSecret, 32);
      await limit('password-ip', ip, 60);
      await limit('password-email', address, 15);
      const user = await store.byEmail(address);
      if (!await crypto.verifyPassword(secret, user?.password_hash) || !complete(user)) fail(401, 'unauthorized');
      return { status: 200, data: { ...crypto.sign(user, now()), userId: user.id, vault: vault(user) } };
    }
    if (!['GET /v1/me', 'DELETE /v1/me', 'GET /v1/vault', 'PUT /v1/vault', 'PUT /v1/auth/password'].includes(route))
      fail(404, 'not_found');
    const user = await authenticate(authorization);
    if (route === 'GET /v1/me') return { status: 200, data: { userId: user.id, email: user.email,
      passwordUpdatedAt: iso(user.password_updated_at) } };
    if (route === 'GET /v1/vault') return { status: 200, data: vault(user) };
    if (route === 'PUT /v1/vault') {
      object(body, ['expectedUpdatedAt', 'ciphertext']);
      const expected = timestamp(body.expectedUpdatedAt);
      const ciphertext = binary(body.ciphertext, 29, MAX_CIPHERTEXT);
      if (equal(ciphertext, user.ciphertext)) return { status: 200, data: { updatedAt: iso(user.updated_at) } };
      const saved = expected === iso(user.updated_at)
        && await store.saveVault(user, ciphertext, nextTime(user.updated_at, now()), expected);
      if (saved) return { status: 200, data: { updatedAt: iso(saved.updated_at) } };
      const current = await authenticate(authorization);
      if (equal(ciphertext, current.ciphertext)) return { status: 200, data: { updatedAt: iso(current.updated_at) } };
      fail(409, 'sync_conflict');
    }
    await limit('password-user', user.id, 15);
    if (route === 'DELETE /v1/me') {
      object(body, ['loginSecret']);
      if (!await crypto.verifyPassword(binary(body.loginSecret, 32), user.password_hash)) fail(401, 'unauthorized');
      if (!await store.deleteUser(user)) fail(401, 'unauthorized');
      return { status: 204 };
    }
    object(body, ['oldLoginSecret', 'expectedPasswordUpdatedAt', 'expectedUpdatedAt', 'salt', 'newLoginSecret', 'ciphertext']);
    const input = encryptedInput(body);
    timestamp(body.expectedPasswordUpdatedAt);
    timestamp(body.expectedUpdatedAt);
    if (body.expectedPasswordUpdatedAt !== iso(user.password_updated_at)) fail(401, 'unauthorized');
    if (!await crypto.verifyPassword(binary(body.oldLoginSecret, 32), user.password_hash)) fail(401, 'unauthorized');
    if (equal(input.salt, user.salt)) fail(400, 'invalid_input');
    if (body.expectedUpdatedAt !== iso(user.updated_at)) fail(409, 'sync_conflict');
    const passwordHash = await crypto.passwordHash(input.loginSecret);
    const result = await store.setPassword(user, { ...input, passwordHash },
      nextTime(user.password_updated_at, now()), nextTime(user.updated_at, now()));
    if (!result) { await authenticate(authorization); fail(409, 'sync_conflict'); }
    return { status: 200, data: { passwordUpdatedAt: iso(result.password_updated_at), updatedAt: iso(result.updated_at) } };
  }
  return { dispatch, cleanup: () => store.cleanup(new Date(now())) };
}
