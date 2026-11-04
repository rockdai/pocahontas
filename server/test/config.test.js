import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { configFromEnv } from '../src/config.js';
import { createMailer, signMail } from '../src/mail.js';

const environment = () => ({ DATABASE_URL: 'postgres://fixture:fixture@localhost/fixture',
  DATABASE_TLS: 'false', SIGNING_KEY: Buffer.alloc(32, 1).toString('base64url'),
  VERIFICATION_KEY: Buffer.alloc(32, 2).toString('base64url'),
  MAIL_SENDER: 'test@example.com', MAIL_ACCESS_KEY_ID: 'public-test-id', MAIL_ACCESS_KEY_SECRET: 'public-test-secret' });

test('deployment rejects shared keys and remote unverified database TLS', () => {
  const env = environment();
  assert.equal(configFromEnv(env).pool.max, 2);
  assert.throws(() => configFromEnv({ ...env, VERIFICATION_KEY: env.SIGNING_KEY }));
  assert.throws(() => configFromEnv({ ...env, DATABASE_URL: 'postgres://fixture@db.example.com/fixture' }));
  assert.throws(() => configFromEnv({ ...env, DATABASE_URL: env.DATABASE_URL + '?sslmode=disable' }));
  assert.throws(() => configFromEnv({ ...env, MAIL_ENDPOINT: 'http://mail.example.com' }));
  assert.equal(configFromEnv({ ...env, DATABASE_TLS: undefined }).pool.ssl.rejectUnauthorized, true);
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
  assert.equal(captured.fields.get('ToAddress'), 'person@example.com');
  assert.ok(captured.fields.get('TextBody').includes('01234567'));
  await assert.rejects(createMailer(config, async () => ({ ok: true, json: async () => ({ Code: 'InvalidAddress' }) }))
    .sendCode('person@example.com', '01234567'));
});
