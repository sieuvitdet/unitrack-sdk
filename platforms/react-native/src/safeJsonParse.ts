// safeJsonParse — wraps JSON.parse and reports failures to UniTrack.
//
// Usage:
//   const user = safeJsonParse<User>('User', responseText);
//   if (user) { /* ... */ }

import UniTrack from './index';

export default function safeJsonParse<T = unknown>(
  targetType: string,
  raw: string
): T | null {
  try {
    return JSON.parse(raw) as T;
  } catch (e: any) {
    const stack = (e?.stack ?? '').split('\n').slice(0, 8).join('\n');
    UniTrack.track('json_parse_error', {
      type:         targetType,
      error:        `${e?.name ?? 'Error'}: ${e?.message ?? ''}`,
      stack,
      data_preview: raw.slice(0, 200),
    });
    return null;
  }
}
