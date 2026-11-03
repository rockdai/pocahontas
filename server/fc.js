import { fcHandler } from './src/app.js';
import { createRuntime } from './src/runtime.js';

let runtime;
const instance = () => runtime ??= createRuntime();
export const handler = async event => fcHandler(instance().app)(event);
export const cleanup = async () => instance().service.cleanup();
