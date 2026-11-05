import { ApiError, DEFAULT_ADMIN_EMAIL, type Caller } from './model.ts';

/** Comma-separated verified emails allowed to write. Defaults to the project editor. */
export function adminEmails(): Set<string> {
  const raw = process.env.ADMIN_EMAILS?.trim() || DEFAULT_ADMIN_EMAIL;
  return new Set(raw.split(',').map(item => item.trim().toLowerCase()).filter(Boolean));
}

export function isAdmin(caller: { email?: string; emailVerified?: boolean }): boolean {
  const email = caller.email?.trim().toLowerCase();
  return Boolean(email && caller.emailVerified === true && adminEmails().has(email));
}

/**
 * Writes (create, publish, upload, pointer moves, record edits) require a verified
 * email listed in ADMIN_EMAILS. A signed-in account with any other email is rejected.
 */
export function assertAdmin(caller: Caller) {
  if (caller.anonymous || !caller.uid) {
    throw new ApiError(401, 'unauthenticated', 'Sign in before changing buildings.');
  }
  if (!isAdmin(caller)) {
    throw new ApiError(403, 'forbidden', 'Only an authorized account can change buildings.');
  }
}
