import test from 'node:test';
import assert from 'node:assert/strict';
import { authorizationCodeBody, authorizeUrl, codeChallenge, idTokenClaims, logoutUrl, refreshTokenBody } from './cognitoOAuth.ts';

test('Google authorize URL is the hosted PKCE code flow', () => {
  const url = new URL(authorizeUrl({
    domain: 'https://gnarly-naijei.auth.us-east-1.amazoncognito.com/',
    clientId: '1osnrt38iuqvf5laum1tnj1hdn',
    redirectUri: 'https://naijei.com/gnarly/',
    challenge: 'abc',
    state: 'state-1',
  }));
  assert.equal(url.origin, 'https://gnarly-naijei.auth.us-east-1.amazoncognito.com');
  assert.equal(url.pathname, '/oauth2/authorize');
  assert.equal(url.searchParams.get('identity_provider'), 'Google');
  assert.equal(url.searchParams.get('response_type'), 'code');
  assert.equal(url.searchParams.get('client_id'), '1osnrt38iuqvf5laum1tnj1hdn');
  assert.equal(url.searchParams.get('redirect_uri'), 'https://naijei.com/gnarly/');
  assert.equal(url.searchParams.get('scope'), 'openid email');
  assert.equal(url.searchParams.get('code_challenge'), 'abc');
  assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(url.searchParams.get('state'), 'state-1');
  assert.equal(url.searchParams.get('client_secret'), null);
});

test('token requests exchange the code and refresh without a client secret', () => {
  const code = authorizationCodeBody({ clientId: 'client', code: 'auth-code', redirectUri: 'http://localhost:5173/', verifier: 'verifier' });
  assert.equal(code.get('grant_type'), 'authorization_code');
  assert.equal(code.get('code'), 'auth-code');
  assert.equal(code.get('code_verifier'), 'verifier');
  assert.equal(code.get('redirect_uri'), 'http://localhost:5173/');
  assert.equal(code.get('client_secret'), null);
  const refresh = refreshTokenBody('client', 'refresh-1');
  assert.equal(refresh.get('grant_type'), 'refresh_token');
  assert.equal(refresh.get('refresh_token'), 'refresh-1');
  const logout = new URL(logoutUrl('gnarly-naijei.auth.us-east-1.amazoncognito.com', 'client', 'http://localhost:5173/'));
  assert.equal(logout.pathname, '/logout');
  assert.equal(logout.searchParams.get('logout_uri'), 'http://localhost:5173/');
});

test('PKCE challenge is S256 and the ID token email claims are readable', async () => {
  const challenge = await codeChallenge('verifier');
  assert.match(challenge, /^[A-Za-z0-9_-]+$/);
  assert.equal(challenge.includes('='), false);
  const payload = Buffer.from(JSON.stringify({ sub: 'user-1', email: 'NJ277@cornell.edu', email_verified: true, exp: 10 })).toString('base64url');
  const claims = idTokenClaims(`header.${payload}.sig`);
  assert.equal(claims.sub, 'user-1');
  assert.equal(claims.email, 'NJ277@cornell.edu');
  assert.equal(claims.emailVerified, true);
  assert.equal(claims.exp, 10);
});
