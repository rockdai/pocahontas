import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createCipheriv, hkdfSync, pbkdf2Sync, randomBytes } from 'node:crypto';
import pg from 'pg';
import { createApp } from '../src/app.js';
import { createService } from '../src/service.js';
import { Store } from '../src/store.js';

export async function database() {
  const directory = mkdtempSync(join(tmpdir(), 'pocahontas-pg-'));
  const data = join(directory, 'data');
  const command = name => process.env.PG_BIN ? join(process.env.PG_BIN, name) : name;
  // macOS postgres aborts startup when libintl has to discover an unset locale.
  const run = (name, args) => execFileSync(command(name), args, { stdio: 'pipe', env: { ...process.env, LC_ALL: 'C' } });
  let started = false, pool;
  try {
    run('initdb', ['-D', data, '-A', 'trust', '--no-locale', '-E', 'UTF8']);
    run('pg_ctl', ['-D', data, '-l', join(directory, 'postgres.log'), '-o', `-F -k ${directory} -c listen_addresses=''`, '-w', 'start']);
    started = true;
    pool = new pg.Pool({ host: directory, database: 'postgres', max: 4 });
    await pool.query(readFileSync(new URL('../schema.sql', import.meta.url), 'utf8'));
    return { pool, async close() {
      await pool.end();
      run('pg_ctl', ['-D', data, '-m', 'fast', '-w', 'stop']);
      rmSync(directory, { recursive: true, force: true });
    } };
  } catch (error) {
    await pool?.end();
    if (started) run('pg_ctl', ['-D', data, '-m', 'fast', '-w', 'stop']);
    rmSync(directory, { recursive: true, force: true });
    throw error;
  }
}

export function client(password = 'Pocahontas test password 2026', records = [], salt = randomBytes(32)) {
  const master = pbkdf2Sync(password.normalize('NFC'), salt, 600000, 32, 'sha256');
  const login = Buffer.from(hkdfSync('sha256', master, salt, 'pocahontas/login/v1', 32));
  const key = Buffer.from(hkdfSync('sha256', master, salt, 'pocahontas/data/v1', 32));
  function encrypt(items) {
    const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, nonce);
    cipher.setAAD(Buffer.from('pocahontas/snapshot/v1\n'));
    return Buffer.concat([nonce, cipher.update(JSON.stringify({ schemaVersion: 1, records: items })),
      cipher.final(), cipher.getAuthTag()]).toString('base64url');
  }
  return { salt: salt.toString('base64url'), loginSecret: login.toString('base64url'), ciphertext: encrypt(records), encrypt, key };
}

export function fixture(pool, options = {}) {
  const secretKey = Buffer.alloc(32, 1);
  const messages = [], logs = [];
  let time = Date.now();
  const store = new Store(pool);
  const service = createService({ store, secretKey, now: () => time,
    issuanceDelay: 0, logger: event => logs.push(event),
    mailer: { async sendCode(email, code) { messages.push({ email, code }); } }, ...options });
  const app = createApp(service, event => logs.push(event));
  async function request(method, path, body, token, extra = {}) {
    const response = await app({ method, path, body: body === undefined ? Buffer.alloc(0) : Buffer.from(JSON.stringify(body)),
      headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
      ip: '127.0.0.1', ...extra });
    return { ...response, data: response.body ? JSON.parse(response.body) : null };
  }
  async function register(email) {
    const keys = client();
    const issued = await request('POST', '/v1/auth/register/code', { email });
    const code = messages.at(-1).code;
    time += 10;
    const registered = await request('POST', '/v1/auth/register', { codeId: issued.data.codeId, code,
      salt: keys.salt, loginSecret: keys.loginSecret, ciphertext: keys.ciphertext });
    if (registered.statusCode !== 201) throw new Error(JSON.stringify(registered.data));
    const login = await request('POST', '/v1/auth/login', { email, loginSecret: keys.loginSecret });
    return { ...keys, ...login.data, email };
  }
  return { app, service, store, request, register, messages, logs, secretKey,
    tick: (milliseconds = 10) => time += milliseconds, now: () => time };
}
