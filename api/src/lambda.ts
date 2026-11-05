import { createAwsDeps } from './awsBackend.ts';
import { handleApi } from './http.ts';

const deps = createAwsDeps();

type FunctionUrlEvent = {
  rawPath?: string;
  rawQueryString?: string;
  headers?: Record<string, string | undefined>;
  body?: string | null;
  isBase64Encoded?: boolean;
  requestContext?: { http?: { method?: string; sourceIp?: string } };
};

/** Lambda Function URL payload format 2.0. JWT checks stay in the handler. */
export async function handler(event: FunctionUrlEvent) {
  const method = event.requestContext?.http?.method || 'GET';
  const path = event.rawPath || '/';
  const query = event.rawQueryString ? `?${event.rawQueryString}` : '';
  const body = !event.body || method === 'GET' || method === 'HEAD'
    ? undefined
    : event.isBase64Encoded ? Buffer.from(event.body, 'base64') : event.body;
  const headers = new Headers();
  for (const [key, value] of Object.entries(event.headers ?? {})) {
    if (value != null) headers.set(key, value);
  }
  const request = new Request(`https://lambda.local${path}${query}`, { method, headers, body });
  const response = await handleApi(deps, request, { ip: event.requestContext?.http?.sourceIp });
  const bytes = Buffer.from(await response.arrayBuffer());
  const out: Record<string, string> = {};
  response.headers.forEach((value, key) => { out[key] = value; });
  return { statusCode: response.status, headers: out, body: bytes.toString('utf8'), isBase64Encoded: false };
}
