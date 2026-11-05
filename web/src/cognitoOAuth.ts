/** Hosted-UI helpers for Cognito's Google IdP. The pool and domain are not modified here. */

export const DEFAULT_COGNITO_DOMAIN = 'gnarly-naijei.auth.us-east-1.amazoncognito.com';
export const HOSTED_REDIRECTS = ['https://naijei.com/gnarly/', 'http://localhost:5173/'] as const;

export function hostedHost(domain: string) {
  return domain.trim().replace(/^https?:\/\//, '').replace(/\/$/, '');
}

export function normalizeRedirect(uri: string) {
  const trimmed = uri.trim();
  if (!trimmed) return '';
  return trimmed.endsWith('/') ? trimmed : `${trimmed}/`;
}

export function base64Url(bytes: Uint8Array) {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

export function codeVerifier() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64Url(bytes);
}

export async function codeChallenge(verifier: string) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return base64Url(new Uint8Array(digest));
}

export function authorizeUrl(options: { domain: string; clientId: string; redirectUri: string; challenge: string; state: string }) {
  const url = new URL(`https://${hostedHost(options.domain)}/oauth2/authorize`);
  url.searchParams.set('identity_provider', 'Google');
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', options.clientId);
  url.searchParams.set('redirect_uri', options.redirectUri);
  url.searchParams.set('scope', 'openid email');
  url.searchParams.set('code_challenge', options.challenge);
  url.searchParams.set('code_challenge_method', 'S256');
  url.searchParams.set('state', options.state);
  return url.toString();
}

export function tokenEndpoint(domain: string) {
  return `https://${hostedHost(domain)}/oauth2/token`;
}

export function logoutUrl(domain: string, clientId: string, logoutUri: string) {
  const url = new URL(`https://${hostedHost(domain)}/logout`);
  url.searchParams.set('client_id', clientId);
  url.searchParams.set('logout_uri', logoutUri);
  return url.toString();
}

export function authorizationCodeBody(input: { clientId: string; code: string; redirectUri: string; verifier: string }) {
  const body = new URLSearchParams();
  body.set('grant_type', 'authorization_code');
  body.set('client_id', input.clientId);
  body.set('code', input.code);
  body.set('redirect_uri', input.redirectUri);
  body.set('code_verifier', input.verifier);
  return body;
}

export function refreshTokenBody(clientId: string, refreshToken: string) {
  const body = new URLSearchParams();
  body.set('grant_type', 'refresh_token');
  body.set('client_id', clientId);
  body.set('refresh_token', refreshToken);
  return body;
}

export type IdTokenClaims = { sub: string; email: string; emailVerified: boolean; exp: number };

export function idTokenClaims(idToken: string): IdTokenClaims {
  try {
    const part = idToken.split('.')[1] || '';
    const padded = part.replace(/-/g, '+').replace(/_/g, '/');
    const json = atob(padded.padEnd(padded.length + (4 - padded.length % 4) % 4, '='));
    const payload = JSON.parse(json) as Record<string, unknown>;
    const email = typeof payload.email === 'string' ? payload.email : '';
    return {
      sub: typeof payload.sub === 'string' ? payload.sub : '',
      email,
      emailVerified: payload.email_verified === true || String(payload.email_verified) === 'true',
      exp: typeof payload.exp === 'number' ? payload.exp : 0,
    };
  } catch {
    throw new Error('The Cognito ID token could not be read.');
  }
}
