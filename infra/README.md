# Gnarly API stack

CDK app for a Lambda Function URL. It imports DynamoDB table `gnarly` and bucket `gnarly-data-402275401617-us-east-1`. It does not create those resources, Cognito users, or DNS records.

Deploy steps, environment variables, and the admin-email rule are in [docs/aws.md](../docs/aws.md).

```sh
npm install
npm run bundle
npx cdk diff
npx cdk deploy
```

`npm run bundle` writes the Lambda zip contents to `infra/build`. The function handler is `dist/lambda.handler` in that directory. Redeploy that asset after API changes. `cdk deploy` was not run by the migration itself.
