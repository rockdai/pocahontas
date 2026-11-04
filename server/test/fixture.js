import { createServer } from 'node:http';
import { writeFileSync } from 'node:fs';
import { once } from 'node:events';
import { database, fixture } from './helpers.js';
import { httpHandler } from '../src/app.js';

const db = await database();
const test = fixture(db.pool, { now: Date.now });
let failNextWrite = false;
const handle = httpHandler(async request => {
  const result = await test.app(request);
  const mutation = request.method === 'PUT'
    || ['POST /v1/auth/register', 'POST /v1/auth/password/reset'].includes(`${request.method} ${request.path}`);
  if (failNextWrite && mutation && result.statusCode >= 200 && result.statusCode < 300) {
    failNextWrite = false;
    return { ...result, statusCode: 503, body: JSON.stringify({ error: { message: 'Test: response lost after commit.' } }) };
  }
  return result;
});
const server = createServer((request, response) => {
  const url = new URL(request.url, 'http://localhost');
  if (url.pathname === '/test/fail-next-write' && request.method === 'POST') {
    failNextWrite = true;
    response.writeHead(204);
    response.end();
    return;
  }
  if (url.pathname === '/test/code' && request.method === 'GET') {
    const code = test.messages.findLast(message => message.email === url.searchParams.get('email'))?.code;
    response.writeHead(code ? 200 : 404, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    response.end(JSON.stringify({ code }));
    return;
  }
  handle(request, response);
}).listen(0, '127.0.0.1');
await once(server, 'listening');
const url = `http://127.0.0.1:${server.address().port}`;
if (process.argv[2]) writeFileSync(process.argv[2], url, { mode: 0o600 });
process.stdout.write('Account fixture ready on loopback.\n');
for (const signal of ['SIGTERM', 'SIGINT']) process.once(signal, async () => {
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  await db.close();
  process.exit(0);
});
