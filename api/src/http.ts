import type { IncomingMessage, ServerResponse } from 'node:http';
import { ApiError, type Caller } from './model.ts';
import { PublishApi, type Deps } from './service.ts';

const JSON_HEADERS = { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' };
const DEFAULT_ORIGINS = 'https://naijei.com,http://localhost:5173,http://localhost:4173';

export function createHandler(deps: Deps & { trustProxy?: boolean; corsOrigins?: string[] }) {
  const trustProxy = deps.trustProxy ?? (process.env.TRUST_PROXY === '1' || Boolean(process.env.K_SERVICE || process.env.FUNCTION_TARGET));
  return async function handler(req: IncomingMessage & { body?: unknown }, res: ServerResponse) {
    const chunks: Buffer[] = [];
    if (!Buffer.isBuffer(req.body) && typeof req.body !== 'string' && !(req.body && typeof req.body === 'object')) {
      for await (const chunk of req) {
        chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
      }
    }
    const body = Buffer.isBuffer(req.body)
      ? req.body
      : typeof req.body === 'string'
        ? req.body
        : req.body && typeof req.body === 'object'
          ? JSON.stringify(req.body)
          : (chunks.length ? Buffer.concat(chunks) : undefined);
    const method = req.method || 'GET';
    const headers = new Headers();
    for (const [key, value] of Object.entries(req.headers)) {
      if (value == null || key === 'host' || key === 'connection' || key === 'content-length') continue;
      headers.set(key, Array.isArray(value) ? value.join(',') : value);
    }
    const request = new Request(`http://localhost${req.url || '/'}`, {
      method,
      headers,
      body: method === 'GET' || method === 'HEAD' || body == null ? undefined : typeof body === 'string' ? body : new Uint8Array(body),
    });
    const response = await handleApi(deps, request, { ip: clientIp(req, trustProxy) });
    const bytes = Buffer.from(await response.arrayBuffer());
    const out: Record<string, string> = {};
    response.headers.forEach((value, key) => { out[key] = value; });
    res.writeHead(response.status, out);
    res.end(bytes);
  };
}

export async function handleApi(deps: Deps & { trustProxy?: boolean; corsOrigins?: string[] }, request: Request, context: { ip?: string } = {}): Promise<Response> {
  const api = new PublishApi(deps);
  const corsOrigins = new Set(deps.corsOrigins ?? (process.env.GNARLY_CORS_ORIGINS ?? DEFAULT_ORIGINS).split(',').map(item => item.trim()).filter(Boolean));
  const origin = request.headers.get('origin');
  const cors: Record<string, string> = {};
  if (origin && corsOrigins.has(origin)) {
    cors['access-control-allow-origin'] = origin;
    cors.vary = 'Origin';
    cors['access-control-allow-headers'] = 'Authorization, Content-Type';
    cors['access-control-allow-methods'] = 'GET, POST, PUT, OPTIONS';
    cors['access-control-max-age'] = '600';
  }
  try {
    if (request.method === 'OPTIONS') {
      if (origin && !corsOrigins.has(origin)) throw new ApiError(403, 'forbidden', 'This origin cannot call the publish API.');
      return new Response(null, { status: 204, headers: cors });
    }
    if (origin && !corsOrigins.has(origin)) throw new ApiError(403, 'forbidden', 'This origin cannot call the publish API.');
    const url = new URL(request.url || '/', 'http://localhost');
    if (request.method === 'GET' && url.pathname === '/healthz') return json(200, { ok: true }, cors);
    const read = isRead(request.method, url.pathname);
    const caller = await authenticate(request, deps, read, context.ip);
    const building = /^\/v1\/buildings\/([^/]+)(?:\/(.*))?$/.exec(url.pathname);
    if (request.method === 'POST' && url.pathname === '/v1/buildings') {
      return json(200, await api.createBuilding(caller, await readJson(request)), cors);
    }
    if (request.method === 'GET' && url.pathname === '/v1/buildings') {
      return json(200, await api.listBuildings(caller), cors);
    }
    if (request.method === 'GET' && url.pathname === '/v1/records') {
      return json(200, await api.listRecords(caller), cors);
    }
    if (request.method === 'PUT' && url.pathname === '/v1/records') {
      return json(200, await api.saveRecord(caller, await readJson(request)), cors);
    }
    if (request.method === 'POST' && url.pathname === '/v1/downloads') {
      return json(200, await api.signDownload(caller, await readJson(request)), cors);
    }
    if (request.method === 'POST' && url.pathname === '/v1/uploads') {
      return json(200, await api.signEditUpload(caller, await readJson(request)), cors);
    }
    if (!building) throw new ApiError(404, 'not_found', 'Unknown publish API route.');
    const buildingId = decodeURIComponent(building[1]);
    const rest = building[2] ?? '';
    if (request.method === 'GET' && rest === '') {
      return json(200, await api.buildingDetail(caller, buildingId), cors);
    }
    if (request.method === 'GET' && rest === 'package') {
      return json(200, await api.downloadPackage(caller, buildingId, url.searchParams), cors);
    }
    const version = /^versions\/([^/]+)$/.exec(rest);
    if (request.method === 'GET' && version) {
      return json(200, await api.versionDetail(caller, buildingId, decodeURIComponent(version[1])), cors);
    }
    if (request.method === 'POST' && rest === 'publishes') {
      return json(200, await api.startPublish(caller, buildingId, await readJson(request)), cors);
    }
    if (request.method === 'POST' && rest === 'pointers') {
      return json(200, await api.movePointer(caller, buildingId, await readJson(request)), cors);
    }
    const publish = /^publishes\/([^/]+)\/commit$/.exec(rest);
    if (request.method === 'POST' && publish) {
      return json(200, await api.commitPublish(caller, buildingId, decodeURIComponent(publish[1])), cors);
    }
    if (request.method === 'POST' && rest === 'train-splat') {
      return json(200, await api.trainSplat(caller, buildingId, await readJson(request)), cors);
    }
    throw new ApiError(404, 'not_found', 'Unknown publish API route.');
  } catch (error) {
    if (error instanceof ApiError) {
      const headers: Record<string, string> = { ...JSON_HEADERS, ...cors };
      if (error.status === 429 && typeof error.details.retryAfterSeconds === 'number') {
        headers['retry-after'] = String(error.details.retryAfterSeconds);
      }
      return new Response(JSON.stringify({ error: { code: error.code, message: error.message, ...error.details } }), { status: error.status, headers });
    }
    console.error(error);
    return json(500, { error: { code: 'internal', message: 'The publish API failed.' } }, cors);
  }
}

function isRead(method: string, pathname: string) {
  if (method === 'GET' && (pathname === '/v1/buildings' || pathname === '/v1/records')) return true;
  if (method === 'GET' && /^\/v1\/buildings\/[^/]+$/.test(pathname)) return true;
  if (method === 'GET' && /^\/v1\/buildings\/[^/]+\/package$/.test(pathname)) return true;
  if (method === 'GET' && /^\/v1\/buildings\/[^/]+\/versions\/[^/]+$/.test(pathname)) return true;
  if (method === 'POST' && pathname === '/v1/downloads') return true;
  return false;
}

async function authenticate(request: Request, deps: Deps, anonymousOk: boolean, ipOverride?: string): Promise<Caller> {
  const headerValue = request.headers.get('authorization');
  const token = headerValue?.startsWith('Bearer ') ? headerValue.slice(7).trim() : '';
  const ip = (ipOverride || 'unknown').slice(0, 80);
  if (!token) {
    if (anonymousOk) return { uid: `anon:${ip}`, ip, anonymous: true };
    throw new ApiError(401, 'unauthenticated', 'Sign in before changing buildings.');
  }
  const user = await deps.verifyToken(token);
  if (!user.uid) throw new ApiError(401, 'unauthenticated', 'Sign in before changing buildings.');
  return { uid: user.uid, ip, email: user.email, emailVerified: user.emailVerified === true };
}

export function clientIp(req: IncomingMessage, trustProxy: boolean): string {
  if (trustProxy) {
    const value = header(req, 'x-forwarded-for');
    const first = value?.split(',')[0]?.trim();
    if (first) return first.slice(0, 80);
  }
  return req.socket.remoteAddress || 'unknown';
}

async function readJson(request: Request): Promise<unknown> {
  const text = await request.text();
  if (!text) return {};
  if (text.length > 1_000_000) throw new ApiError(413, 'too_large', 'JSON body exceeds 1 MB.');
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw new ApiError(400, 'invalid_json', 'Request body is not JSON.');
  }
}

function header(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

function json(status: number, body: unknown, extra: Record<string, string>) {
  return new Response(JSON.stringify(body), { status, headers: { ...JSON_HEADERS, ...extra } });
}
