import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { S3Client } from '@aws-sdk/client-s3';
import { DynamoDBDocumentClient } from '@aws-sdk/lib-dynamodb';
import { CognitoJwtVerifier } from 'aws-jwt-verify';
import { ApiError } from './model.ts';
import { quotasFromEnv } from './quotas.ts';
import type { Deps } from './service.ts';
import { DynamoCounters, DynamoMetadata } from './dynamoStore.ts';
import { S3ObjectStore } from './s3Store.ts';

const DEFAULT_BUCKET = 'gnarly-data-402275401617-us-east-1';
const DEFAULT_TABLE = 'gnarly';
const DEFAULT_REGION = 'us-east-1';
const DEFAULT_POOL = 'us-east-1_pQIUmVbPJ';
const DEFAULT_CLIENT = '1osnrt38iuqvf5laum1tnj1hdn';

export function createAwsDeps(): Deps & { trustProxy?: boolean } {
  const region = process.env.AWS_REGION || process.env.GNARLY_AWS_REGION || DEFAULT_REGION;
  const table = process.env.GNARLY_TABLE || DEFAULT_TABLE;
  const bucket = process.env.GNARLY_BUCKET || DEFAULT_BUCKET;
  const dynamo = DynamoDBDocumentClient.from(new DynamoDBClient({ region }), {
    marshallOptions: { removeUndefinedValues: true },
  });
  return {
    now: () => new Date(),
    adminUid: process.env.GNARLY_ADMIN_UID || '',
    quotas: quotasFromEnv(),
    verifyToken: createCognitoVerifier(),
    objects: new S3ObjectStore(new S3Client({ region }), bucket),
    metadata: new DynamoMetadata(dynamo, table),
    counters: new DynamoCounters(dynamo, table),
    trustProxy: process.env.TRUST_PROXY === '1',
  };
}

/** Verifies a Cognito ID token. Email lives on the ID token, not the access token. */
export function createCognitoVerifier(): Deps['verifyToken'] {
  const userPoolId = process.env.COGNITO_USER_POOL_ID || DEFAULT_POOL;
  const clientId = process.env.COGNITO_CLIENT_ID || DEFAULT_CLIENT;
  const verifier = CognitoJwtVerifier.create({ userPoolId, tokenUse: 'id', clientId });
  return async token => {
    try {
      const payload = await verifier.verify(token);
      const email = typeof payload.email === 'string' ? payload.email : undefined;
      const emailVerified = payload.email_verified === true || String(payload.email_verified) === 'true';
      return { uid: payload.sub, email, emailVerified };
    } catch {
      throw new ApiError(401, 'unauthenticated', 'Sign in again.');
    }
  };
}
