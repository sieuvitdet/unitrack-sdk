// @unitrack/firebase — forwards every UniTrack event to Firebase Analytics.
//
// Prerequisites (standard @react-native-firebase setup, done by the app):
//   • android/app/google-services.json + google-services gradle plugin
//   • ios/<App>/GoogleService-Info.plist added to the app target
//
//   import { FirebaseProvider } from '@unitrack/firebase';
//   UniTrack.addProvider(new FirebaseProvider());
//   await UniTrack.initialize(apiKey);
//
// Firebase imposes strict naming rules (event/param names ≤40 chars,
// alphanumeric + underscore, start with a letter; values string/number/bool),
// so names and parameters are sanitized.

import type { AnalyticsProvider, EventProperties } from '@unitrack/react-native';

export class FirebaseProvider implements AnalyticsProvider {
  private analytics: any = null;

  initialize(): void {
    try {
      // @react-native-firebase auto-initializes the default app from the
      // native google-services files; we just grab the analytics module.
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const mod = require('@react-native-firebase/analytics');
      this.analytics = mod.default ? mod.default() : mod();
      console.log('[unitrack/firebase] Firebase Analytics ready');
    } catch (e) {
      console.warn('[unitrack/firebase] @react-native-firebase/analytics not installed');
    }
  }

  track(name: string, properties: EventProperties): void {
    this.analytics?.logEvent(this.sanitizeName(name), this.sanitizeParams(properties));
  }

  setUser(userId: string | null, traits: EventProperties): void {
    this.analytics?.setUserId(userId);
    for (const [k, v] of Object.entries(traits)) {
      this.analytics?.setUserProperty(this.sanitizeName(k), v == null ? null : String(v));
    }
  }

  setScreen(name: string): void {
    this.analytics?.logScreenView({ screen_name: name, screen_class: name });
  }

  // --- Firebase naming/value constraints ----------------------------------

  private sanitizeName(name: string): string {
    let s = name.replace(/[^a-zA-Z0-9_]/g, '_');
    if (s.length && !/^[a-zA-Z]/.test(s)) s = 'e_' + s;
    if (s.length > 40) s = s.slice(0, 40);
    return s;
  }

  private sanitizeParams(props: EventProperties): Record<string, string | number | boolean> {
    const out: Record<string, string | number | boolean> = {};
    for (const [k, v] of Object.entries(props)) {
      if (v == null) continue;
      const key = this.sanitizeName(k);
      if (typeof v === 'number' || typeof v === 'boolean' || typeof v === 'string') {
        out[key] = typeof v === 'string' && v.length > 100 ? v.slice(0, 100) : v;
      } else {
        const s = JSON.stringify(v) ?? String(v);
        out[key] = s.length > 100 ? s.slice(0, 100) : s;
      }
    }
    return out;
  }
}
