import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { configFromEnv } from '../src/config.js';
import { createMailer, signMail } from '../src/mail.js';

const environment = () => ({ DATABASE_URL: 'postgres://fixture:fixture@localhost/fixture',
  DATABASE_TLS: 'false', SECRET_KEY: Buffer.alloc(32, 1).toString('base64url'),
  MAIL_SENDER: 'test@example.com', ACCESS_KEY_ID: 'public-test-id', ACCESS_KEY_SECRET: 'public-test-secret' });

test('HTTP entrypoint defaults to loopback and accepts an explicit HOST', async t => {
  for (const host of [undefined, '0.0.0.0']) await t.test(host ?? 'default', async t => {
    const child = spawn(process.execPath, ['--input-type=module', '-e', `
      import { Server } from 'node:net';
      const listen = Server.prototype.listen;
      Server.prototype.listen = function (...args) {
        this.once('listening', () => process.send(this.address()));
        return listen.apply(this, args);
      };
      await import(${JSON.stringify(new URL('../src/main.js', import.meta.url).href)});
    `], { env: { ...environment(), PORT: '0', ...(host ? { HOST: host } : {}) },
      stdio: ['ignore', 'ignore', 'pipe', 'ipc'], timeout: 5000, killSignal: 'SIGKILL' });
    let stderr = '';
    child.stderr.on('data', data => { stderr += data; });
    const exited = once(child, 'exit');
    t.after(async () => { child.kill(); await exited; });
    const [address] = await Promise.race([once(child, 'message'), exited.then(([code, signal]) => {
      throw new Error(`HTTP startup exited (${code ?? signal}): ${stderr}`);
    })]);
    assert.equal(address.address, host ?? '127.0.0.1');
    assert.ok(address.port > 0);
    const response = await fetch(`http://127.0.0.1:${address.port}/healthz`, {
      headers: { connection: 'close' }, signal: AbortSignal.timeout(3000),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true });
  });
});

test('HTTP entrypoint rejects invalid ports', () => {
  for (const port of ['invalid', '-1', '65536']) {
    assert.throws(() => execFileSync(process.execPath, [fileURLToPath(new URL('../src/main.js', import.meta.url))], {
      env: { ...environment(), PORT: port }, timeout: 5000, stdio: 'pipe',
    }), error => error.status !== 0 && /ERR_SOCKET_BAD_PORT/.test(error.stderr.toString()));
  }
});

test('deployment requires both AccessKey credentials', () => {
  for (const name of ['ACCESS_KEY_ID', 'ACCESS_KEY_SECRET']) {
    for (const value of [undefined, '']) {
      assert.throws(() => configFromEnv({ ...environment(), [name]: value }), { message: `Missing ${name}` });
    }
  }
});

test('deployment accepts one shared secret and rejects missing or malformed keys', () => {
  const env = environment();
  assert.deepEqual(configFromEnv(env).secretKey, Buffer.from(env.SECRET_KEY, 'base64url'));
  for (const value of [undefined, '', ' ', 'invalid!', env.SECRET_KEY + '=',
    env.SECRET_KEY.slice(0, -1) + 'F',
    Buffer.alloc(31).toString('base64url'), Buffer.alloc(33).toString('base64url')]) {
    assert.throws(() => configFromEnv({ ...env, SECRET_KEY: value }),
      { message: 'SECRET_KEY must be 32 bytes in canonical Base64URL' });
  }
});

test('deployment rejects remote unverified database TLS', () => {
  const env = environment();
  assert.equal(configFromEnv(env).pool.max, 2);
  assert.throws(() => configFromEnv({ ...env, DATABASE_URL: 'postgres://fixture@db.example.com/fixture' }));
  assert.throws(() => configFromEnv({ ...env, DATABASE_URL: env.DATABASE_URL + '?sslmode=disable' }));
  assert.throws(() => configFromEnv({ ...env, MAIL_ENDPOINT: 'http://mail.example.com' }));
  assert.deepEqual(configFromEnv({ ...env, DATABASE_TLS: undefined,
    DATABASE_URL: 'postgres://fixture@db.example.com/fixture' }).pool.ssl, { rejectUnauthorized: true });
});

test('DirectMail signs canonical encoded parameters and handles provider errors', async () => {
  const parameters = { Action: 'SingleSendMail', TextBody: "a b+!*'()", ToAddress: 'user@example.com' };
  const canonical = 'Action=SingleSendMail&TextBody=a%20b%2B%21%2A%27%28%29&ToAddress=user%40example.com';
  const expected = createHmac('sha1', 'test&').update('POST&%2F&' + encodeURIComponent(canonical)).digest('base64');
  const signed = new URLSearchParams(signMail(parameters, 'test'));
  assert.equal(signed.get('Signature'), expected);
  let captured;
  const config = configFromEnv(environment()).mail;
  await createMailer(config, async (url, request) => {
    captured = { url, request, fields: new URLSearchParams(request.body) };
    return { ok: true, json: async () => ({ RequestId: 'test-delivery' }) };
  }).sendCode('person@example.com', '01234567');
  assert.equal(captured.url, 'https://dm.aliyuncs.com/');
  assert.equal(captured.request.redirect, 'error');
  assert.equal(captured.fields.get('AccessKeyId'), environment().ACCESS_KEY_ID);
  const signature = captured.fields.get('Signature');
  captured.fields.delete('Signature');
  const expectedRequest = new URLSearchParams(signMail(Object.fromEntries(captured.fields), environment().ACCESS_KEY_SECRET));
  assert.equal(signature, expectedRequest.get('Signature'));
  assert.equal(captured.fields.get('ToAddress'), 'person@example.com');
  assert.ok(captured.fields.get('TextBody').includes('01234567'));
  await assert.rejects(createMailer(config, async () => ({ ok: true, json: async () => ({ Code: 'InvalidAddress' }) }))
    .sendCode('person@example.com', '01234567'));
});
