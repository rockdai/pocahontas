export class APIError extends Error {
  constructor(status, code) {
    super(code);
    this.status = status;
    this.code = code;
  }
}

export const fail = (status, code) => { throw new APIError(status, code); };
export const MAX_CIPHERTEXT = 1024 * 1024 + 28;
export const MAX_BODY = 1.5 * 1024 * 1024;

export function object(value, fields) {
  if (!value || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).length !== fields.length
      || fields.some(key => !Object.hasOwn(value, key))) fail(400, 'invalid_input');
  return value;
}

export function email(value) {
  if (typeof value !== 'string') fail(400, 'invalid_input');
  const normalized = value.trim().toLowerCase();
  const parts = normalized.split('@');
  if (normalized.length > 254 || parts.length !== 2 || parts[0].length > 64
      || !/^[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*$/.test(parts[0])
      || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/.test(parts[1])
      || parts[1].split('.').some(label => label.length > 63)) fail(400, 'invalid_input');
  return normalized;
}

export function binary(value, length, max = length) {
  if (typeof value !== 'string' || value.length > Math.ceil(max * 4 / 3)
      || !/^[A-Za-z0-9_-]+$/.test(value)) fail(400, 'invalid_input');
  const result = Buffer.from(value, 'base64url');
  if (result.length < length || result.length > max || result.toString('base64url') !== value)
    fail(400, 'invalid_input');
  return result;
}

export function uuid(value) {
  if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value))
    fail(400, 'invalid_input');
  return value;
}

export function timestamp(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(value)
      || !Number.isFinite(Date.parse(value)) || new Date(value).toISOString() !== value)
    fail(400, 'invalid_input');
  return value;
}

export function encryptedInput(body) {
  return {
    salt: binary(body.salt, 32),
    loginSecret: binary(body.newLoginSecret ?? body.loginSecret, 32),
    ciphertext: binary(body.ciphertext, 29, MAX_CIPHERTEXT),
  };
}

export const iso = value => new Date(value).toISOString();
export const nextTime = (old, now) => new Date(Math.max(now, new Date(old).getTime() + 1));
