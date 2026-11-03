import pg from 'pg';
import { createApp } from './app.js';
import { configFromEnv } from './config.js';
import { createMailer } from './mail.js';
import { createService } from './service.js';
import { Store } from './store.js';

export function createRuntime(env) {
  const config = configFromEnv(env);
  const logger = event => process.stderr.write(`${JSON.stringify(event)}\n`);
  const pool = new pg.Pool(config.pool);
  pool.on('error', () => logger({ event: 'database_connection_failed' }));
  const service = createService({ ...config, store: new Store(pool), mailer: createMailer(config.mail), logger });
  return { app: createApp(service, logger), service, close: () => pool.end() };
}
