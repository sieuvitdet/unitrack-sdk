// UniTrackFirebaseCrashlytics — non-fatal error helper.
//
// One call records to Crashlytics (full symbolicated stack via dSYM upload)
// AND fires application_error through UniTrack (portal + Snowplow + Firebase
// Analytics). The C++ signal-trap crash handler in UniTrack core stays
// independent — it fires on the NEXT launch with reason=signal, while this
// helper is for non-fatal try/catch sites.
//
//   import { UniTrackFirebaseCrashlytics } from '@unitrack/firebase';
//
//   try { await riskyCall(); }
//   catch (e) { UniTrackFirebaseCrashlytics.recordError(e); }
//
//   UniTrackFirebaseCrashlytics.log('entering checkout step 2');
//   UniTrackFirebaseCrashlytics.setCustomKey('cart_size', 3);

import UniTrack from '@unitrack/react-native';

interface CrashlyticsModule {
  recordError: (e: Error, jsErrorName?: string) => Promise<void>;
  log: (m: string) => void;
  setAttribute: (key: string, value: string) => Promise<void>;
  setUserId: (id: string) => Promise<void>;
}

function rnCrashlytics(): CrashlyticsModule | null {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const mod = require('@react-native-firebase/crashlytics');
    const fn = mod.default ?? mod;
    return fn() as CrashlyticsModule;
  } catch {
    return null;
  }
}

export class UniTrackFirebaseCrashlytics {
  /** Record a non-fatal error. Sends to Crashlytics + fires
   *  application_error (is_fatal=false). Safe to call even when the
   *  Crashlytics module isn't installed — UniTrack still gets the signal. */
  static async recordError(
    error: unknown,
    opts: { reason?: string; context?: Record<string, unknown> } = {},
  ): Promise<void> {
    const e = error instanceof Error ? error : new Error(String(error));
    const c = rnCrashlytics();
    if (c) {
      try {
        if (opts.context) {
          for (const k of Object.keys(opts.context)) {
            const v = opts.context[k];
            if (v != null) await c.setAttribute(k, String(v));
          }
        }
        await c.recordError(e, opts.reason);
      } catch {
        /* swallow — don't let a Crashlytics setup bug hide errors */
      }
    }

    const props: Record<string, unknown> = {
      message: e.message,
      is_fatal: false,
    };
    if (opts.reason)  props.reason  = opts.reason;
    if (opts.context) props.context = opts.context;
    if (e.stack) {
      props.stack = e.stack.split('\n').slice(0, 20).join('\n');
    }
    await UniTrack.track('application_error', props);
  }

  /** Attach a custom key (breadcrumb) to subsequent crash reports. */
  static async setCustomKey(key: string, value: unknown): Promise<void> {
    const c = rnCrashlytics();
    if (!c) return;
    try { await c.setAttribute(key, String(value)); } catch { /* */ }
  }

  /** Append a line to the Crashlytics log ring buffer (surfaces in the
   *  crash report's "Logs" section). */
  static log(message: string): void {
    const c = rnCrashlytics();
    if (!c) return;
    try { c.log(message); } catch { /* */ }
  }

  /** Sync the identified UniTrack user into Crashlytics so crash reports
   *  carry the user id. Pass null/empty on logout. */
  static async syncUser(userId: string | null | undefined): Promise<void> {
    const c = rnCrashlytics();
    if (!c) return;
    try { await c.setUserId(userId ?? ''); } catch { /* */ }
  }
}
