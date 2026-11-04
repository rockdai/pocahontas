import { readFileSync } from 'node:fs';
import { binary } from './validation.js';

export function configFromEnv(env = process.env) {
  function required(name) {
    if (!env[name]) throw new Error(`Missing ${name}`);
    return env[name];
  }
  function key(name) {
    try { return binary(required(name), 32); }
    catch { throw new Error(`${name} must be 32 bytes in canonical Base64URL`); }
  }
  const signingKey = key('SIGNING_KEY'), verificationKey = key('VERIFICATION_KEY');
  if (signingKey.equals(verificationKey)) throw new Error('Use independent signing and verification keys');
  const databaseURL = required('DATABASE_URL');
  const database = new URL(databaseURL);
  if (database.search) throw new Error('Configure PostgreSQL TLS with DATABASE_CA_FILE, not URL parameters');
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(database.hostname);
  if (env.DATABASE_TLS === 'false' && !local) throw new Error('Only a loopback database may disable TLS');
  const ssl = env.DATABASE_TLS === 'false' ? false : { rejectUnauthorized: true,
    ...(env.DATABASE_CA_FILE ? { ca: readFileSync(env.DATABASE_CA_FILE, 'utf8') } : {}) };
  const endpoint = new URL(env.MAIL_ENDPOINT ?? 'https://dm.aliyuncs.com/');
  if (endpoint.protocol !== 'https:' || endpoint.username || endpoint.password) throw new Error('MAIL_ENDPOINT must use HTTPS');
  return { signingKey, verificationKey,
    pool: { connectionString: databaseURL, ssl, max: 2, connectionTimeoutMillis: 5000,
      idleTimeoutMillis: 30000, statement_timeout: 5000, query_timeout: 6000 },
    mail: { endpoint: endpoint.href, region: env.MAIL_REGION ?? 'cn-hangzhou', sender: required('MAIL_SENDER'),
      accessKeyID: required('ACCESS_KEY_ID'), accessKeySecret: required('ACCESS_KEY_SECRET'),
      securityToken: env.MAIL_SECURITY_TOKEN },
  };
}
