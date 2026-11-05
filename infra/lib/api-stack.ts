import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CfnOutput, Duration, Stack, type StackProps } from 'aws-cdk-lib';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import { Construct } from 'constructs';

const ACCOUNT = '402275401617';
const REGION = 'us-east-1';
const TABLE_ARN = `arn:aws:dynamodb:${REGION}:${ACCOUNT}:table/gnarly`;
const BUCKET = 'gnarly-data-402275401617-us-east-1';
const BUCKET_ARN = `arn:aws:s3:::${BUCKET}`;

/** Lambda Function URL in front of the existing table and bucket. It does not create either. */
export class GnarlyApiStack extends Stack {
  constructor(scope: Construct, id: string, props: StackProps) {
    super(scope, id, props);
    const asset = join(dirname(fileURLToPath(import.meta.url)), '../build');
    if (!existsSync(join(asset, 'dist/lambda.js'))) {
      throw new Error('Missing infra/build. From infra/, run npm run bundle before cdk synth.');
    }
    const fn = new lambda.Function(this, 'Api', {
      functionName: 'gnarly-api',
      description: 'Gnarly publish API (DynamoDB, S3, Cognito).',
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: 'dist/lambda.handler',
      code: lambda.Code.fromAsset(asset),
      memorySize: 1024,
      timeout: Duration.seconds(300),
      environment: {
        GNARLY_BACKEND: 'aws',
        GNARLY_TABLE: 'gnarly',
        GNARLY_BUCKET: BUCKET,
        COGNITO_USER_POOL_ID: 'us-east-1_pQIUmVbPJ',
        COGNITO_CLIENT_ID: '1osnrt38iuqvf5laum1tnj1hdn',
        ADMIN_EMAILS: 'nj277@cornell.edu',
        GNARLY_CORS_ORIGINS: 'https://naijei.com,http://localhost:5173,http://localhost:4173',
        GNARLY_SCHEMA_DIR: '/var/task/shared',
        TRUST_PROXY: '0',
      },
    });
    fn.addToRolePolicy(new iam.PolicyStatement({
      sid: 'GnarlyTable',
      actions: [
        'dynamodb:GetItem',
        'dynamodb:PutItem',
        'dynamodb:UpdateItem',
        'dynamodb:Query',
        'dynamodb:ConditionCheckItem',
        'dynamodb:DescribeTable',
      ],
      resources: [TABLE_ARN, `${TABLE_ARN}/index/GSI1`],
    }));
    fn.addToRolePolicy(new iam.PolicyStatement({
      sid: 'GnarlyObjects',
      actions: ['s3:GetObject', 's3:PutObject', 's3:AbortMultipartUpload'],
      resources: [`${BUCKET_ARN}/*`],
    }));
    // HeadObject on a missing key returns 403 unless the role can list the bucket.
    fn.addToRolePolicy(new iam.PolicyStatement({
      sid: 'GnarlyListBuildingsPrefix',
      actions: ['s3:ListBucket'],
      resources: [BUCKET_ARN],
      conditions: { StringLike: { 's3:prefix': ['buildings/*'] } },
    }));
    const url = fn.addFunctionUrl({ authType: lambda.FunctionUrlAuthType.NONE });
    new CfnOutput(this, 'ApiUrl', { value: url.url, description: 'Set this as VITE_GNARLY_API_BASE. Do not change DNS from this stack.' });
  }
}
