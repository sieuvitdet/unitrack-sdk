// SHA-256 hashing với salt. crypto.subtle là native browser API — async,
// không cần lib. Port từ Flutter PIIHash + iOS CryptoKit version.
//
// Công thức: sha256_hex(salt + raw). Cùng salt → cùng hash → BE dedup user.
// In-memory cache để tránh hash lại cùng (raw, salt) — kèm salt prefix vào
// key cache để rotate salt invalidate cache đúng.

const cache = new Map<string, string>();

let configuredSalt = '';

export function configureSalt(salt: string): void {
  configuredSalt = salt || '';
  cache.clear();
}

export function getSalt(): string {
  return configuredSalt;
}

export async function sha256(raw: string, salt?: string): Promise<string> {
  const useSalt = salt ?? configuredSalt;
  if (!raw) return '';
  const cacheKey = `${useSalt}|${raw}`;
  const cached = cache.get(cacheKey);
  if (cached) return cached;

  if (typeof crypto === 'undefined' || !crypto.subtle) {
    // Fallback: không hash → return raw. Caller chịu trách nhiệm BE chấp
    // nhận. Web không support crypto.subtle = browser quá cũ (IE11).
    return raw;
  }

  const enc = new TextEncoder().encode(useSalt + raw);
  const buf = await crypto.subtle.digest('SHA-256', enc);
  const hex = Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
  cache.set(cacheKey, hex);
  return hex;
}

export function clearCache(): void {
  cache.clear();
}
