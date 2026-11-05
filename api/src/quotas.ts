import { defaultQuotas, type Quota, type Quotas } from './model.ts';

export function quotasFromEnv(): Quotas {
  const override = (action: keyof Quotas, field: keyof Quota, fallback: number) => {
    const raw = process.env[`GNARLY_RATE_${action.toUpperCase()}_${field === 'windowMs' ? 'WINDOW_MS' : field.toUpperCase()}`];
    const parsed = raw ? Number(raw) : fallback;
    return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
  };
  const quota = (action: keyof Quotas): Quota => ({
    windowMs: override(action, 'windowMs', defaultQuotas[action].windowMs),
    user: override(action, 'user', defaultQuotas[action].user),
    building: override(action, 'building', defaultQuotas[action].building),
    ip: override(action, 'ip', defaultQuotas[action].ip),
  });
  return { publish: quota('publish'), list: quota('list'), download: quota('download') };
}
