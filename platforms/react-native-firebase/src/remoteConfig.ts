// UniTrackFirebaseRemoteConfig — Firebase Remote Config wrapper.
//
// UniTrack exposes a unified `UniTrack.getRemoteValue<T>(key, defaultValue)`
// that resolves in this order:
//   1. Portal `sdk_config.custom_values[key]` (operator-edited)
//   2. Firebase Remote Config (this helper, if `activate()` was called)
//   3. Caller's defaultValue
//
// This helper is opt-in: call `activate({ defaults, minimumFetchInterval })`
// once at startup AFTER Firebase has initialized.
//
//   import { UniTrackFirebaseRemoteConfig } from '@unitrack/firebase';
//   await UniTrackFirebaseRemoteConfig.activate({
//     defaults: { feature_camera_grid: false, home_banner_copy: 'Welcome' },
//     minimumFetchIntervalMillis: 3600_000,
//   });
//
//   const on = await UniTrack.getRemoteValue('feature_camera_grid', false);

interface RemoteConfigValue {
  asString: () => string;
  asBoolean: () => boolean;
  asNumber: () => number;
}
interface RemoteConfigModule {
  setConfigSettings: (s: Record<string, number>) => Promise<void>;
  setDefaults: (d: Record<string, unknown>) => Promise<void>;
  fetchAndActivate: () => Promise<boolean>;
  getValue: (key: string) => RemoteConfigValue;
}

function rnRemoteConfig(): RemoteConfigModule | null {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const mod = require('@react-native-firebase/remote-config');
    const fn = mod.default ?? mod;
    return fn() as RemoteConfigModule;
  } catch {
    return null;
  }
}

export class UniTrackFirebaseRemoteConfig {
  private static rc: RemoteConfigModule | null = null;
  private static activated = false;

  static get isActivated(): boolean {
    return UniTrackFirebaseRemoteConfig.activated;
  }

  /** Fetch + activate Remote Config. Safe to call multiple times. */
  static async activate(opts: {
    defaults?: Record<string, string | number | boolean>;
    minimumFetchIntervalMillis?: number;
    fetchTimeoutMillis?: number;
  } = {}): Promise<void> {
    const rc = UniTrackFirebaseRemoteConfig.rc ?? (UniTrackFirebaseRemoteConfig.rc = rnRemoteConfig());
    if (!rc) {
      // Module not installed — silently no-op so the unified resolver chain
      // falls through to defaults.
      return;
    }
    await rc.setConfigSettings({
      minimumFetchIntervalMillis: opts.minimumFetchIntervalMillis ?? 3600_000,
      fetchTimeMillis:            opts.fetchTimeoutMillis ?? 10_000,
    });
    if (opts.defaults && Object.keys(opts.defaults).length) {
      await rc.setDefaults(opts.defaults);
    }
    try { await rc.fetchAndActivate(); } catch { /* network down — defaults still apply */ }
    UniTrackFirebaseRemoteConfig.activated = true;
  }

  /** Typed sync getters mirroring Firebase's accessors. Use these directly
   *  when you specifically want RC (vs. the unified UniTrack chain). */
  static getString(key: string, defaultValue = ''): string {
    const rc = UniTrackFirebaseRemoteConfig.rc;
    if (!rc) return defaultValue;
    const v = rc.getValue(key).asString();
    return v === '' ? defaultValue : v;
  }
  static getBool(key: string, defaultValue = false): boolean {
    const rc = UniTrackFirebaseRemoteConfig.rc;
    if (!rc) return defaultValue;
    return rc.getValue(key).asBoolean();
  }
  static getNumber(key: string, defaultValue = 0): number {
    const rc = UniTrackFirebaseRemoteConfig.rc;
    if (!rc) return defaultValue;
    return rc.getValue(key).asNumber();
  }
}
