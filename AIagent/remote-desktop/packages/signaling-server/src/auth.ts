import bcrypt from "bcryptjs";
import {
  MAX_PASSWORD_ATTEMPTS,
  IP_BLOCK_DURATION_MS,
  ERROR_CODES,
} from "@remote-desktop/shared";
import type { AttemptRecord } from "./types.js";

const SALT_ROUNDS = 10;

const attempts = new Map<string, AttemptRecord>();

export async function hashPassword(password: string): Promise<string> {
  return bcrypt.hash(password, SALT_ROUNDS);
}

export async function verifyPassword(
  password: string,
  hash: string
): Promise<boolean> {
  return bcrypt.compare(password, hash);
}

export function checkRateLimit(ip: string): {
  allowed: boolean;
  errorCode?: string;
} {
  const record = attempts.get(ip);
  if (!record) return { allowed: true };

  if (record.blockedUntil !== null && Date.now() < record.blockedUntil) {
    return { allowed: false, errorCode: ERROR_CODES.TOO_MANY_ATTEMPTS };
  }

  if (record.blockedUntil !== null && Date.now() >= record.blockedUntil) {
    attempts.delete(ip);
    return { allowed: true };
  }

  return { allowed: true };
}

export function recordFailedAttempt(ip: string): void {
  const record = attempts.get(ip) ?? { count: 0, blockedUntil: null };
  record.count += 1;

  if (record.count >= MAX_PASSWORD_ATTEMPTS) {
    record.blockedUntil = Date.now() + IP_BLOCK_DURATION_MS;
  }

  attempts.set(ip, record);
}

export function clearAttempts(ip: string): void {
  attempts.delete(ip);
}
