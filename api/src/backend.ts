import { createAwsDeps } from './awsBackend.ts';
import { createFirebaseDeps } from './firebaseBackend.ts';
import type { Deps } from './service.ts';

/** `GNARLY_BACKEND=aws` selects DynamoDB, S3, and Cognito. Anything else keeps Firebase. */
export function createDeps(): Deps & { trustProxy?: boolean } {
  const backend = (process.env.GNARLY_BACKEND || 'firebase').trim().toLowerCase();
  if (backend === 'aws') return createAwsDeps();
  if (backend === 'firebase') return createFirebaseDeps();
  throw new Error(`GNARLY_BACKEND must be "aws" or "firebase" (received ${JSON.stringify(process.env.GNARLY_BACKEND)}).`);
}
