// UniTrackFirebaseCrashlytics — non-fatal error helper.
//
// Thin façade so the app calls one API and gets both:
//   • Crashlytics.recordError() — full symbolicated stack via the app's
//     dSYM / ProGuard upload
//   • UniTrack.track('application_error', …) — same incident through the
//     UniTrack pipeline (portal + Snowplow + Firebase Analytics)
//
// The native crash trap in UniTrack core stays independent — that fires on
// the NEXT launch with reason=signal, while this helper is for non-fatal
// `record(error:)` calls inside try/catch sites.
//
// Usage:
//   try {
//     await riskyCall();
//   } catch (e, st) {
//     UniTrackFirebaseCrashlytics.recordError(e, st);
//   }
//
//   UniTrackFirebaseCrashlytics.log('entering checkout flow step 2');
//   UniTrackFirebaseCrashlytics.setCustomKey('cart_size', 3);

import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:unitrack/unitrack.dart';

class UniTrackFirebaseCrashlytics {
  UniTrackFirebaseCrashlytics._();

  /// Record a non-fatal error. Forwards to Crashlytics for symbolication +
  /// fires `application_error` (is_fatal=false) so the portal + Snowplow
  /// see the same incident.
  static Future<void> recordError(
    Object error,
    StackTrace? stack, {
    Map<String, Object?> context = const {},
    String? reason,
  }) async {
    // Crashlytics goes first — if FlutterFire isn't initialized, this throws
    // and the UniTrack.track call below still runs in the catch handler.
    try {
      // setCustomKey takes one key/value at a time. Loop the context bag so
      // every entry shows up on the Crashlytics report.
      for (final entry in context.entries) {
        final v = entry.value;
        if (v is String || v is num || v is bool) {
          await FirebaseCrashlytics.instance.setCustomKey(entry.key, v as Object);
        } else if (v != null) {
          await FirebaseCrashlytics.instance.setCustomKey(entry.key, v.toString());
        }
      }
      await FirebaseCrashlytics.instance.recordError(
        error,
        stack,
        reason: reason,
        fatal: false,
      );
    } catch (_) {
      // Swallow — UniTrack.track still gives us a signal even if Crashlytics
      // isn't wired up yet. Don't let a Crashlytics setup bug hide errors.
    }

    final props = <String, Object?>{
      'message': error.toString(),
      'is_fatal': false,
    };
    if (reason != null && reason.isNotEmpty) props['reason'] = reason;
    if (context.isNotEmpty) props['context'] = context;
    if (stack != null) {
      props['stack'] = stack.toString().split('\n').take(20).join('\n');
    }
    await UniTrack.instance.track('application_error', properties: props);
  }

  /// Attach a custom key to subsequent crash reports (breadcrumb context).
  /// Mirrors `FirebaseCrashlytics.instance.setCustomKey(key, value)`.
  static Future<void> setCustomKey(String key, Object value) async {
    try {
      if (value is String || value is num || value is bool) {
        await FirebaseCrashlytics.instance.setCustomKey(key, value);
      } else {
        await FirebaseCrashlytics.instance.setCustomKey(key, value.toString());
      }
    } catch (_) {}
  }

  /// Append a line to the Crashlytics log ring buffer. Surfaces in the crash
  /// report's "Logs" section.
  static Future<void> log(String message) async {
    try {
      await FirebaseCrashlytics.instance.log(message);
    } catch (_) {}
  }

  /// Sync the identified UniTrack user into Crashlytics so crash reports
  /// carry the user id. Pass empty string / null on logout.
  static Future<void> syncUser(String? userId) async {
    try {
      await FirebaseCrashlytics.instance.setUserIdentifier(userId ?? '');
    } catch (_) {}
  }
}
