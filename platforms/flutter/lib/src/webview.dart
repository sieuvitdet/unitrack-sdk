// UniTrack WebView auto-capture helper for Flutter.
//
// `webview_flutter` is the canonical WebView for Flutter on iOS+Android. It
// exposes a `WebViewController` with a `NavigationDelegate` callback bag —
// attach() registers an extra layer that fires UniTrack events without
// stomping on the app's own delegate.
//
// Usage from the consuming app:
//   import 'package:unitrack/src/webview.dart' as ut_wv;
//   final controller = WebViewController();
//   ut_wv.attachUniTrackWebView(
//     controller,
//     setNavigationDelegate: (delegate) =>
//         controller.setNavigationDelegate(delegate),
//     createNavigationDelegate: ({onPageStarted, onPageFinished}) =>
//         NavigationDelegate(
//           onPageStarted: onPageStarted,
//           onPageFinished: onPageFinished,
//         ),
//   );
//
// Why the indirection: this lib is shipped with the unitrack package, which
// does NOT have webview_flutter as a dependency (most apps don't use webviews).
// The app supplies the two adapters above so we don't have to import
// webview_flutter from inside this file — keeps the lib loadable everywhere.

import '../unitrack.dart';

/// Wires UniTrack onto a WebViewController-like object. `setNavigationDelegate`
/// is called once with a delegate built by [createNavigationDelegate]. The
/// delegate fires `webview_open` on first load + host change, and
/// `webview_navigate` on same-host follow-ups.
void attachUniTrackWebView(
  Object controller, {
  required void Function(Object delegate) setNavigationDelegate,
  required Object Function({
    void Function(String url)? onPageStarted,
    void Function(String url)? onPageFinished,
  }) createNavigationDelegate,
}) {
  String? firstHost;
  setNavigationDelegate(
    createNavigationDelegate(
      onPageStarted: (url) {
        if (url.isEmpty) return;
        final host = Uri.tryParse(url)?.host;
        if (firstHost == null || firstHost != host) {
          firstHost = host;
          UniTrack.instance.trackWebViewOpen(url);
        } else {
          UniTrack.instance
              .track('webview_navigate', properties: {'url': url});
        }
      },
    ),
  );
}
