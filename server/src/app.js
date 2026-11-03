import { randomUUID } from 'node:crypto';
import { APIError, fail, MAX_BODY } from './validation.js';

const messages = {
  invalid_input: 'Check the submitted information.', invalid_code: 'The code is invalid or expired. Request a new code.',
  unauthorized: 'Sign in again to continue.', sync_conflict: 'Your library changed. Download it before retrying.',
  rate_limited: 'Too many attempts. Try again later.', unavailable: 'The service is temporarily unavailable.',
  busy: 'The service is busy. Try again later.', too_large: 'The request is too large.',
  not_found: 'This endpoint does not exist.', unsupported_media: 'Send a JSON request.',
};

export function createApp(service, logger = () => {}) {
  return async ({ method, path, headers = {}, body = Buffer.alloc(0), ip = 'unknown' }) => {
    const requestId = randomUUID();
    const responseHeaders = { 'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'x-request-id': requestId };
    try {
      const normalized = Object.fromEntries(Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value]));
      if (body.length > MAX_BODY) fail(413, 'too_large');
      let parsed;
      if (['POST', 'PUT', 'DELETE'].includes(method)) {
        if (normalized['content-encoding'] && normalized['content-encoding'] !== 'identity') fail(415, 'unsupported_media');
        if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(normalized['content-type'] ?? '')) fail(415, 'unsupported_media');
        try { parsed = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(body)); }
        catch { fail(400, 'invalid_input'); }
      } else if (body.length) fail(400, 'invalid_input');
      const result = await service.dispatch({ method, path, body: parsed,
        authorization: normalized.authorization, ip });
      return { statusCode: result.status, headers: responseHeaders, isBase64Encoded: false,
        body: result.status === 204 ? '' : JSON.stringify(result.data) };
    } catch (error) {
      const known = error instanceof APIError;
      const statusCode = known ? error.status : 503;
      const code = known ? error.code : 'unavailable';
      if (!known) logger({ event: 'request_failed', requestId });
      if (statusCode === 429) responseHeaders['retry-after'] = '900';
      return { statusCode, headers: responseHeaders, isBase64Encoded: false,
        body: JSON.stringify({ error: { code, message: messages[code], requestId } }) };
    }
  };
}

export function httpHandler(app) {
  return async (request, response) => {
    const chunks = [];
    let size = 0;
    try {
      for await (const chunk of request) {
        size += chunk.length;
        if (size > MAX_BODY) {
          response.writeHead(413, { 'content-type': 'application/json', 'cache-control': 'no-store', connection: 'close' });
          response.end(JSON.stringify({ error: { code: 'too_large', message: messages.too_large, requestId: randomUUID() } }));
          return;
        }
        chunks.push(chunk);
      }
      const result = await app({ method: request.method, path: new URL(request.url, 'http://localhost').pathname,
        headers: request.headers, body: Buffer.concat(chunks), ip: request.socket.remoteAddress });
      response.writeHead(result.statusCode, result.headers);
      response.end(result.body);
    } catch {
      if (!response.headersSent) response.writeHead(400, { 'cache-control': 'no-store' });
      response.end();
    }
  };
}

export function fcHandler(app) {
  return async event => {
    const request = JSON.parse(Buffer.isBuffer(event) ? event.toString('utf8') : event);
    const http = request.requestContext?.http;
    if (!http || request.version !== 'v1') throw new Error('Invalid FC HTTP event');
    return app({ method: http.method, path: http.path, headers: request.headers,
      body: Buffer.from(request.body ?? '', request.isBase64Encoded ? 'base64' : 'utf8'), ip: http.sourceIp });
  };
}
