import { createRuntime } from './runtime.js';

const runtime = createRuntime();
try { await runtime.service.cleanup(); }
finally { await runtime.close(); }
