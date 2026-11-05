import { GetObjectCommand, HeadObjectCommand, NotFound, NoSuchKey, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';
import { ApiError } from './model.ts';
import type { ObjectStore } from './store.ts';

type Signer = (client: S3Client, command: PutObjectCommand | GetObjectCommand, options: { expiresIn: number }) => Promise<string>;

export class S3ObjectStore implements ObjectStore {
  private readonly client: S3Client;
  private readonly bucket: string;
  private readonly signer: Signer;

  constructor(client: S3Client, bucket: string, signer: Signer = getSignedUrl) {
    this.client = client;
    this.bucket = bucket;
    this.signer = signer;
  }

  async stat(path: string) {
    try {
      const out = await this.client.send(new HeadObjectCommand({ Bucket: this.bucket, Key: path }));
      return { size: Number(out.ContentLength ?? 0), contentType: out.ContentType };
    } catch (error) {
      if (isMissing(error)) return null;
      throw error;
    }
  }

  async read(path: string, maxBytes: number) {
    const stat = await this.stat(path);
    if (!stat) throw new ApiError(404, 'missing_object', `${path} has not been uploaded.`);
    if (stat.size > maxBytes) throw new ApiError(413, 'too_large', `${path} exceeds its size limit.`);
    try {
      const out = await this.client.send(new GetObjectCommand({ Bucket: this.bucket, Key: path }));
      const bytes = out.Body ? await out.Body.transformToByteArray() : null;
      if (!bytes) throw new ApiError(404, 'missing_object', `${path} has not been uploaded.`);
      return Buffer.from(bytes);
    } catch (error) {
      if (isMissing(error)) throw new ApiError(404, 'missing_object', `${path} has not been uploaded.`);
      throw error;
    }
  }

  async signUpload(path: string, contentType: string, expiresAt: Date) {
    return this.signer(this.client, new PutObjectCommand({
      Bucket: this.bucket,
      Key: path,
      ContentType: contentType,
    }), { expiresIn: expiresIn(expiresAt) });
  }

  async signDownload(path: string, expiresAt: Date) {
    return this.signer(this.client, new GetObjectCommand({ Bucket: this.bucket, Key: path }), { expiresIn: expiresIn(expiresAt) });
  }
}

function expiresIn(expiresAt: Date) {
  return Math.max(1, Math.ceil((expiresAt.getTime() - Date.now()) / 1000));
}

function isMissing(error: unknown) {
  if (error instanceof NotFound || error instanceof NoSuchKey) return true;
  if (!error || typeof error !== 'object') return false;
  const name = (error as { name?: string }).name;
  const status = (error as { $metadata?: { httpStatusCode?: number } }).$metadata?.httpStatusCode;
  return name === 'NotFound' || name === 'NoSuchKey' || status === 404;
}
