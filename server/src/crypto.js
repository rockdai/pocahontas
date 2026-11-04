import { createHmac, pbkdf2, randomBytes, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import { binary, fail, iso, object, timestamp, uuid } from './validation.js';

const derive = promisify(pbkdf2);
const HEADER = Buffer.from('{"alg":"HS256","typ":"JWT"}').toString('base64url');
const TTL = 2592000;
export const ITERATIONS = 600000;
export const digest = (key, value) => createHmac('sha256', key).update(value).digest();
export const equal = (a, b) => Buffer.isBuffer(a) && Buffer.isBuffer(b)
  && a.length === b.length && timingSafeEqual(a, b);
export const codeHash = (key, id, userID, code) => digest(key,
  JSON.stringify(['verification-code/v1', id, userID, code]));

export function createCrypto({ secretKey, maxKDF = 4 }) {
  let running = 0;
  async function hash(secret, salt) {
    if (running >= maxKDF) fail(503, 'busy');
    running++;
    try { return await derive(secret, salt, ITERATIONS, 32, 'sha256'); }
    finally { running--; }
  }
  return {
    async passwordHash(secret) {
      const salt = randomBytes(32);
      return `pbkdf2-sha256$${ITERATIONS}$${salt.toString('base64url')}$${(await hash(secret, salt)).toString('base64url')}`;
    },
    async verifyPassword(secret, record) {
      let salt = Buffer.alloc(32), expected = Buffer.alloc(32), valid = false;
      try {
        const parts = record.split('$');
        if (parts.length === 4 && parts[0] === 'pbkdf2-sha256' && parts[1] === String(ITERATIONS)) {
          salt = binary(parts[2], 32);
          expected = binary(parts[3], 32);
          valid = true;
        }
      } catch { /* Missing or malformed records still pay the same password hashing cost. */ }
      const result = await hash(secret, salt);
      return equal(result, expected) && valid;
    },
    fakeSalt(email) { return digest(secretKey, JSON.stringify(['prelogin/v1', email])); },
    sign(user, now) {
      const iat = Math.floor(now / 1000);
      const payload = { iss: 'pocahontas-server', aud: 'pocahontas-api', sub: user.id,
        passwordUpdatedAt: iso(user.password_updated_at), iat, exp: iat + TTL };
      const input = `${HEADER}.${Buffer.from(JSON.stringify(payload)).toString('base64url')}`;
      return { token: `${input}.${digest(secretKey, input).toString('base64url')}`,
        expiresAt: new Date(payload.exp * 1000).toISOString() };
    },
    verify(token, now) {
      try {
        if (typeof token !== 'string' || token.length > 4096) throw new Error();
        const parts = token.split('.');
        if (parts.length !== 3 || parts[0] !== HEADER) throw new Error();
        const payloadBytes = binary(parts[1], 1, 3072);
        if (!equal(binary(parts[2], 32), digest(secretKey, parts.slice(0, 2).join('.')))) throw new Error();
        const payload = object(JSON.parse(payloadBytes.toString('utf8')),
          ['iss', 'aud', 'sub', 'passwordUpdatedAt', 'iat', 'exp']);
        uuid(payload.sub);
        timestamp(payload.passwordUpdatedAt);
        if (payload.iss !== 'pocahontas-server' || payload.aud !== 'pocahontas-api'
            || !Number.isSafeInteger(payload.iat) || !Number.isSafeInteger(payload.exp)
            || payload.exp !== payload.iat + TTL || payload.iat > Math.floor(now / 1000) + 60
            || payload.exp <= Math.floor(now / 1000)) throw new Error();
        return payload;
      } catch { fail(401, 'unauthorized'); }
    },
  };
}
