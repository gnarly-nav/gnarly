process.env.ADMIN_EMAILS = 'nj277@cornell.edu';

import { createServer, type Server } from 'node:http';
import { once } from 'node:events';
import test from 'node:test';
import assert from 'node:assert/strict';
import { adminEmails, isAdmin } from '../src/authz.ts';
import { createHandler } from '../src/http.ts';
import { ApiError } from '../src/model.ts';
import type { Deps } from '../src/service.ts';
import { MemoryCounters, MemoryMetadata, MemoryObjectStore } from '../src/store.ts';

function world() {
  const metadata = new MemoryMetadata();
  const objects = new MemoryObjectStore();
  const counters = new MemoryCounters();
  const deps: Deps & { trustProxy: boolean; corsOrigins: string[] } = {
    now: () => new Date('2026-10-14T04:00:00Z'),
    adminUid: 'legacy-admin',
    verifyToken: async token => {
      if (!token.startsWith('user:')) throw new ApiError(401, 'unauthenticated', 'Sign in again.');
      const [uid, email, flag] = token.slice('user:'.length).split('|');
      return { uid, email: email || undefined, emailVerified: flag === '1' };
    },
    objects,
    metadata,
    counters,
    trustProxy: true,
    corsOrigins: ['http://localhost:5173', 'https://naijei.com'],
  };
  const server = createServer((req, res) => { void createHandler(deps)(req, res); });
  return { server, metadata, objects, counters };
}

test('admin email check requires a verified address from ADMIN_EMAILS', () => {
  assert.equal(isAdmin({ email: 'NJ277@cornell.edu', emailVerified: true }), true);
  assert.equal(isAdmin({ email: 'nj277@cornell.edu', emailVerified: false }), false);
  assert.equal(isAdmin({ email: 'other@cornell.edu', emailVerified: true }), false);
  assert.equal(isAdmin({ emailVerified: true }), false);
  const previous = process.env.ADMIN_EMAILS;
  process.env.ADMIN_EMAILS = 'editor@example.com, NJ277@cornell.edu';
  try {
    assert.equal(adminEmails().has('editor@example.com'), true);
    assert.equal(isAdmin({ email: 'Editor@example.com', emailVerified: true }), true);
  } finally {
    process.env.ADMIN_EMAILS = previous;
  }
});

test('anonymous visitors can read and only the verified admin email can write', async () => {
  const { server, metadata, objects } = world();
  const base = await listen(server);
  try {
    await metadata.createBuilding({
      id: 'hall', name: 'Hall', status: 'active', activeVersion: 'v1', ownerUid: null,
      legacyOwnerUid: 'firebase-owner', acl: {}, visibility: 'members',
    });
    metadata.versions.set('hall/v1', { id: 'v1', versionNumber: 1, status: 'published', zoneConnectionsPath: 'buildings/hall/v1/zone-connections.json' });
    objects.put('buildings/hall/v1/zone-connections.json', Buffer.from('{"schemaVersion":1,"connections":[]}'), 'application/json');

    const listed = await fetch(base + '/v1/buildings');
    assert.equal(listed.status, 200);
    const library = await listed.json() as { buildings: { id: string }[] };
    assert.equal(library.buildings.some(item => item.id === 'hall'), true);

    const downloaded = await fetch(base + '/v1/downloads', {
      method: 'POST',
      headers: { 'content-type': 'application/json', origin: 'https://naijei.com' },
      body: JSON.stringify({ path: 'buildings/hall/v1/zone-connections.json' }),
    });
    assert.equal(downloaded.status, 200);
    assert.equal(downloaded.headers.get('access-control-allow-origin'), 'https://naijei.com');

    const anonWrite = await fetch(base + '/v1/buildings/hall/publishes', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ files: [{ name: 'zone-connections.json', size: 4, contentType: 'application/json' }] }),
    });
    assert.equal(anonWrite.status, 401);

    const other = await send(base, '/v1/uploads', { path: 'buildings/hall/v1/zone-connections.json', contentType: 'application/json', size: 4 }, 'person', 'person@example.com', true);
    assert.equal(other.status, 403);

    const unverified = await send(base, '/v1/buildings/hall/publishes', { files: [{ name: 'zone-connections.json', size: 4, contentType: 'application/json' }] }, 'admin', 'nj277@cornell.edu', false);
    assert.equal(unverified.status, 403);

    const admin = await send(base, '/v1/buildings/hall/publishes', { files: [{ name: 'zone-connections.json', size: 4, contentType: 'application/json' }] }, 'admin', 'NJ277@cornell.edu', true);
    assert.equal(admin.status, 200);

    const upload = await send(base, '/v1/uploads', { path: 'buildings/hall/v1/zone-connections.json', contentType: 'application/json', size: 4 }, 'admin', 'nj277@cornell.edu', true);
    assert.equal(upload.status, 200);
    const signed = await upload.json() as { method: string; url: string; headers: { 'Content-Type': string } };
    assert.equal(signed.method, 'PUT');
    assert.match(signed.url, /zone-connections/);
    assert.equal(signed.headers['Content-Type'], 'application/json');
  } finally {
    server.close();
  }
});

test('anonymous reads do not consume rate counters', async () => {
  const { server, metadata, objects, counters } = world();
  const base = await listen(server);
  try {
    await metadata.createBuilding({
      id: 'hall', name: 'Hall', status: 'active', activeVersion: 'v1', ownerUid: null, acl: {}, visibility: 'authenticated',
    });
    metadata.versions.set('hall/v1', { id: 'v1', versionNumber: 1, status: 'published' });
    objects.put('buildings/hall/v1/zone-connections.json', Buffer.from('{"schemaVersion":1,"connections":[]}'), 'application/json');
    assert.equal((await fetch(base + '/v1/buildings')).status, 200);
    assert.equal((await fetch(base + '/v1/buildings/hall/package')).status, 200);
    assert.equal((await fetch(base + '/v1/downloads', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ path: 'buildings/hall/v1/zone-connections.json' }),
    })).status, 200);
    assert.equal(counters.counts.size, 0);
    const write = await send(base, '/v1/buildings/hall/publishes', {
      files: [{ name: 'zone-connections.json', size: 2, contentType: 'application/json' }],
    }, 'admin', 'nj277@cornell.edu', true);
    assert.equal(write.status, 200);
    assert.ok(counters.counts.size > 0);
  } finally {
    server.close();
  }
});

async function send(base: string, path: string, body: unknown, uid: string, email: string, verified: boolean) {
  return fetch(base + path, {
    method: 'POST',
    headers: {
      authorization: `Bearer user:${uid}|${email}|${verified ? '1' : '0'}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify(body),
  });
}

async function listen(server: Server) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('no port');
  return `http://127.0.0.1:${address.port}`;
}
