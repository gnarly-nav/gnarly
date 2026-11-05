import { App, Tags } from 'aws-cdk-lib';
import { GnarlyApiStack } from '../lib/api-stack.ts';

const app = new App();
const stack = new GnarlyApiStack(app, 'GnarlyApi', {
  env: { account: '402275401617', region: 'us-east-1' },
  description: 'Gnarly publish API. Imports the existing gnarly table and data bucket.',
});
Tags.of(stack).add('project', 'gnarly');
