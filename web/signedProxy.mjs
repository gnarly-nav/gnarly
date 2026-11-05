const S3_VIRTUAL = /^(.+)\.s3(?:[.-][a-z0-9-]+)?\.amazonaws\.com$/i;
const S3_PATH = /^s3(?:[.-][a-z0-9-]+)?\.amazonaws\.com$/i;

export function readSignedTarget(raw, bucket) {
  const buckets = (Array.isArray(bucket) ? bucket : [bucket]).filter(Boolean);
  if (!raw || !buckets.length) return null;
  let target;
  try { target = new URL(raw); } catch { return null; }
  if (target.protocol !== 'https:' || target.username || target.password) return null;
  if (target.hostname === 'storage.googleapis.com') {
    if (!buckets.some(name => target.pathname.startsWith('/' + name + '/'))) return null;
    return target.toString();
  }
  const virtual = S3_VIRTUAL.exec(target.hostname);
  if (virtual && buckets.includes(virtual[1])) return target.toString();
  if (S3_PATH.test(target.hostname)) {
    const name = decodeURIComponent(target.pathname.split('/')[1] || '');
    if (buckets.includes(name)) return target.toString();
  }
  return null;
}
