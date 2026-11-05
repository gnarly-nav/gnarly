import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const infra = dirname(fileURLToPath(import.meta.url));
const root = join(infra, '..');
const api = join(root, 'api');
const build = join(infra, 'build');
const apiPackage = JSON.parse(readFileSync(join(api, 'package.json'), 'utf8'));
const keep = [
  '@aws-sdk/client-dynamodb',
  '@aws-sdk/lib-dynamodb',
  '@aws-sdk/client-s3',
  '@aws-sdk/s3-request-presigner',
  'aws-jwt-verify',
  'ajv',
  'ajv-formats',
];

execSync('npx tsc -p tsconfig.json', { cwd: api, stdio: 'inherit' });
rmSync(build, { recursive: true, force: true });
mkdirSync(build, { recursive: true });
cpSync(join(api, 'dist'), join(build, 'dist'), { recursive: true });
cpSync(join(root, 'shared'), join(build, 'shared'), { recursive: true });
const dependencies = Object.fromEntries(keep.map(name => [name, apiPackage.dependencies[name]]));
writeFileSync(join(build, 'package.json'), JSON.stringify({
  name: 'gnarly-api-lambda',
  private: true,
  type: 'module',
  dependencies,
}, null, 2));
execSync('npm install --omit=dev', { cwd: build, stdio: 'inherit' });
console.log('Lambda bundle written to infra/build');
