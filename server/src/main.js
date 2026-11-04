import { createServer } from 'node:http';
import { httpHandler } from './app.js';
import { httpOptionsFromEnv } from './config.js';
import { createRuntime } from './runtime.js';

const runtime = createRuntime();
const server = createServer({ requestTimeout: 10000, headersTimeout: 10000,
  maxHeaderSize: 8192 }, httpHandler(runtime.app));
server.listen(httpOptionsFromEnv());
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
  server.close(() => runtime.close());
});
