import test from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { AuthenticationHelper } = require('amazon-cognito-identity-js') as {
  AuthenticationHelper: new (poolName: string) => {
    N: { constructor: new (hex: string, radix: number) => unknown };
    smallAValue: unknown;
    largeAValue: { toString(radix: number): string } | null;
    getLargeAValue(callback: (error: Error | null) => void): void;
    getPasswordAuthenticationKey(
      username: string,
      password: string,
      serverB: unknown,
      salt: unknown,
      callback: (error: Error | null, key: Uint8Array) => void,
    ): void;
  };
};

const secret = '11'.repeat(32);
const serverB = '2'.repeat(64);
const salt = 'ab'.repeat(16);
const clientA =
  'f2c4e7407ccfac452a7c7e1034e8388bf70b3aea30007fd146ae4c54b341d252f7752a43f24cd28368a96f455f9ee00eb4312863c2560b7162587cd2c962b588cae47a9ac339433f9fc7d3563c1abb952acc1e3dd565fc9ecde1ac7cc593627494abc14dbb2410bc3dc4a0cf5e6f2f7af643f1d2c888180b50375a28902031b3c7052284d5d32b9dd8ee35c6c0cb9ee52288bcbc52deb224c55391da65ec10e66f8c41cc7d0c12b7a75f171ada3cb4c21fba22c4ad59ad4685cd63080d92d959cc54fcda8022cb856ce27c6e2ae2c81f6f9fa8cad13cfb22dc202b650e14014498bf3afd56c95a8cf956c46e3aedb2f20b4d1d8ebf2e9ef26955e228142b1168b1bfd7383d403ccbb00d89ca6843e39b7a44d7741a063bd4edb9c054606f59c7416327aa574b2f6d910606d9677c5018d07e080cd342ac446d35fd481f7818c780deb9508aeba3483493e43c98c6885e09883b8feb7e903e16468e7a1fc3df0cc55c71d1b3e4b4574d40699be76bca7abdf7938cfb2068cacca3b49b35a49099';

test('the mobile password challenge matches amazon-cognito-identity-js', async () => {
  const helper = new AuthenticationHelper('pQIUmVbPJ');
  helper.smallAValue = new helper.N.constructor(secret, 16);
  helper.largeAValue = null;
  await new Promise<void>((resolve, reject) => {
    helper.getLargeAValue(error => error ? reject(error) : resolve());
  });
  const publicA = helper.largeAValue as { toString(radix: number): string } | null;
  if (!publicA) throw new Error('missing SRP A');
  assert.equal(publicA.toString(16), clientA);
  const key = await new Promise<Uint8Array>((resolve, reject) => {
    helper.getPasswordAuthenticationKey(
      'nj277@cornell.edu',
      'hunter2',
      new helper.N.constructor(serverB, 16),
      new helper.N.constructor(salt, 16),
      (error, value) => error ? reject(error) : resolve(value),
    );
  });
  assert.equal(Buffer.from(key).toString('hex'), '520fc9074ea5352b6636ae9fedd712f1');
});
