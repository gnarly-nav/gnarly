import test from 'node:test';
import assert from 'node:assert/strict';
import type { S3Client } from '@aws-sdk/client-s3';
import { S3ObjectStore } from '../src/s3Store.ts';

test('presigned urls keep object keys, including spaces', async () => {
  const seen: { name: string; input: Record<string, unknown> }[] = [];
  const client = {
    async send(command: { constructor: { name: string }; input: Record<string, unknown> }) {
      seen.push({ name: command.constructor.name, input: command.input });
      if (command.constructor.name === 'HeadObjectCommand') {
        if (command.input.Key === 'missing') {
          const error = new Error('missing');
          error.name = 'NotFound';
          throw error;
        }
        return { ContentLength: 4, ContentType: 'application/json' };
      }
      if (command.constructor.name === 'GetObjectCommand') {
        return { Body: { transformToByteArray: async () => new Uint8Array([1, 2, 3, 4]) } };
      }
      throw new Error(command.constructor.name);
    },
  };
  const signed: { key?: unknown; type?: unknown }[] = [];
  const store = new S3ObjectStore(client as unknown as S3Client, 'gnarly-data-402275401617-us-east-1', async (_client, command) => {
    const input = command.input;
    signed.push({ key: input.Key, type: 'ContentType' in input ? input.ContentType : undefined });
    return `https://example.test/${encodeURIComponent(String(input.Key))}`;
  });
  const key = 'buildings/hall/v1/zones/zone-a/Zone Plan.json';
  const expires = new Date(Date.now() + 60_000);
  assert.equal(await store.signUpload(key, 'application/json', expires), `https://example.test/${encodeURIComponent(key)}`);
  assert.equal(signed[0]?.key, key);
  assert.equal(signed[0]?.type, 'application/json');
  assert.equal((await store.stat(key))?.size, 4);
  assert.equal((await store.stat('missing')), null);
  assert.equal((await store.read(key, 10)).length, 4);
  assert.ok(seen.some(item => item.name === 'HeadObjectCommand' && item.input.Bucket === 'gnarly-data-402275401617-us-east-1'));
});
