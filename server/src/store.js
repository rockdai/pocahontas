import { randomUUID } from 'node:crypto';

export class Store {
  constructor(pool) { this.pool = pool; }
  async one(sql, values) { return (await this.pool.query(sql, values)).rows[0]; }
  user(id) { return this.one('SELECT * FROM app_user WHERE id = $1 AND deleted_at IS NULL', [id]); }
  byEmail(email) { return this.one('SELECT * FROM app_user WHERE email = $1 AND deleted_at IS NULL', [email]); }
  async pendingUser(email, now) {
    await this.pool.query(`INSERT INTO app_user (created_at, updated_at, id, email)
      VALUES ($1, $1, $2, $3) ON CONFLICT (email) DO NOTHING`, [now, randomUUID(), email]);
    return this.byEmail(email);
  }
  addCode(id, userID, hash, now, expires) {
    return this.pool.query(`INSERT INTO verification (created_at, updated_at, id, user_id, hash, expires_at)
      VALUES ($1, $1, $2, $3, $4, $5)`, [now, id, userID, hash, expires]);
  }
  code(id) { return this.one('SELECT * FROM verification WHERE id = $1 AND deleted_at IS NULL', [id]); }
  consume(id, userID, now) {
    return this.one(`UPDATE verification SET deleted_at = $3, updated_at = $3
      WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL AND expires_at > $3 RETURNING user_id`, [id, userID, now]);
  }
  hit(key, now, expires) {
    return this.one(`INSERT INTO rate_limit (created_at, updated_at, key, hit_count, expires_at)
      VALUES ($2, $2, $1, 1, $3) ON CONFLICT (key) DO UPDATE
      SET hit_count = rate_limit.hit_count + 1, updated_at = $2
      WHERE rate_limit.deleted_at IS NULL AND rate_limit.expires_at > $2 RETURNING hit_count`, [key, now, expires]);
  }
  setPassword(user, value, passwordTime, updatedTime) {
    return this.one(`UPDATE app_user SET salt = $1, password_hash = $2, ciphertext = $3,
      password_updated_at = $4, updated_at = $5 WHERE id = $6 AND deleted_at IS NULL
      AND password_updated_at IS NOT DISTINCT FROM $7::timestamptz AND updated_at = $8 RETURNING *`,
    [value.salt, value.passwordHash, value.ciphertext, passwordTime, updatedTime,
      user.id, user.password_updated_at, user.updated_at]);
  }
  saveVault(user, ciphertext, updated, expected) {
    return this.one(`UPDATE app_user SET ciphertext = $1, updated_at = $2
      WHERE id = $3 AND deleted_at IS NULL AND password_updated_at = $4 AND updated_at = $5 RETURNING *`,
    [ciphertext, updated, user.id, user.password_updated_at, expected]);
  }
  deleteUser(user) {
    return this.one(`DELETE FROM app_user WHERE id = $1 AND deleted_at IS NULL
      AND password_updated_at = $2 RETURNING id`, [user.id, user.password_updated_at]);
  }
  async cleanup(now) {
    const codes = await this.pool.query('DELETE FROM verification WHERE expires_at <= $1', [now]);
    const limits = await this.pool.query('DELETE FROM rate_limit WHERE expires_at <= $1', [now]);
    const pending = await this.pool.query(`DELETE FROM app_user
      WHERE password_updated_at IS NULL AND created_at < $1`, [new Date(now.getTime() - 86400000)]);
    return { verification: codes.rowCount, rateLimit: limits.rowCount, pendingUser: pending.rowCount };
  }
}
