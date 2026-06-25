// UniTrackWebView.swift
//
// Auto-capture WebView opens, navigations, AND in-page clicks on iOS without
// per-call instrumentation.
//
// Strategy:
//   1. Swizzle WKWebView.load(_:) — every WKWebView funnels through this
//      single method, so one swizzle catches every open across the app
//      (in-app browsers, SFSafariViewController fallbacks, third-party
//      SDK web shells). Fires `webview_open` with the URL.
//   2. Swizzle WKWebView.init(frame:configuration:) so EVERY new web view
//      gets a UserContentController script message handler + an inject
//      script. The inject script:
//        • Hooks document click → posts {key, screen, text} back to native
//        • Hooks history pushState/replaceState + popstate → posts navigate
//      Native side fires `click` (kind=click, framework=webview) and
//      `webview_navigate` so the portal sees in-page events without the
//      app having to wire anything.
//
// The handler name "unitrack" is namespaced under window.webkit.messageHandlers,
// and the inject script is gated by an idempotency flag so re-injecting on
// every navigation stays safe.

import Foundation
import WebKit

public enum UniTrackWebView {

    /// Install the WKWebView swizzles. Call once at startup (after
    /// UniTrack.initialize). Subsequent calls are no-ops.
    public static func install() {
        Self.installOnce
    }

    private static let installOnce: Void = {
        swizzleLoad()
        swizzleInit()
    }()

    private static func swizzleLoad() {
        let cls: AnyClass = WKWebView.self
        let original = #selector(WKWebView.load(_:))
        let replacement = #selector(WKWebView.ut_load(_:))
        guard let m1 = class_getInstanceMethod(cls, original),
              let m2 = class_getInstanceMethod(cls, replacement) else { return }
        method_exchangeImplementations(m1, m2)
    }

    private static func swizzleInit() {
        let cls: AnyClass = WKWebView.self
        let original = #selector(WKWebView.init(frame:configuration:))
        let replacement = #selector(WKWebView.init(ut_frame:configuration:))
        guard let m1 = class_getInstanceMethod(cls, original),
              let m2 = class_getInstanceMethod(cls, replacement) else { return }
        method_exchangeImplementations(m1, m2)
    }

    /// JavaScript injected at document start into every WKWebView. Idempotent
    /// via the __unitrack flag so re-injection on history navigation is safe.
    /// Listens for click events in the capture phase so even handlers that
    /// stopPropagation can't hide the event. Resolves element_key from
    /// data-sp-action → data-track-id → title → id → aria-label → tag:text,
    /// and harvests every `data-*` (incl. parsed `data-sp-extra` JSON) into
    /// the `data` map so portal-side filtering can match on any attribute.
    static let injectJS: String = """
    (function(){
      if (window.__unitrack && window.__unitrack.installed) return;
      window.__unitrack = { installed: true };
      function key(el){
        if (!el) return 'unknown';
        var k = el.getAttribute && (el.getAttribute('data-sp-action') ||
                                    el.getAttribute('data-track-id') ||
                                    el.getAttribute('data-testid') ||
                                    el.getAttribute('title') ||
                                    el.id ||
                                    el.getAttribute('aria-label'));
        if (k) return String(k).slice(0, 120);
        var tag = (el.tagName || '').toLowerCase();
        var txt = (el.innerText || el.textContent || '').trim().replace(/\\s+/g, ' ');
        if (txt) return tag + ':' + txt.slice(0, 60);
        return tag || 'unknown';
      }
      // Snake-case "dataSpAction" → "data_sp_action" so portal column names
      // align with the rest of the SDK convention (Snowplow uses snake_case
      // for self-describing-event keys).
      function snake(camel){
        return camel.replace(/[A-Z]/g, function(c){ return '_' + c.toLowerCase(); });
      }
      function collectData(el){
        var out = {};
        if (!el || !el.attributes) return out;
        var ds = el.dataset || {};
        for (var k in ds){
          var v = ds[k];
          if (v == null) continue;
          var key = snake(k);
          // data-sp-extra is JSON — parse so portal sees structured fields,
          // not a quoted string. Fall back to raw text if parse fails.
          if (k === 'spExtra' || k === 'extra'){
            try { out[key] = JSON.parse(v); }
            catch(e) { out[key] = String(v).slice(0, 500); }
          } else {
            out[key] = String(v).slice(0, 200);
          }
        }
        // Keep title/aria-label too — common spots for human labels.
        var t = el.getAttribute && el.getAttribute('title');
        if (t) out.title = String(t).slice(0, 200);
        var a = el.getAttribute && el.getAttribute('aria-label');
        if (a) out.aria_label = String(a).slice(0, 200);
        return out;
      }
      function post(payload){
        try {
          window.webkit.messageHandlers.unitrack.postMessage(payload);
        } catch(e) {}
      }
      document.addEventListener('click', function(ev){
        var t = ev.target;
        // Walk up to the nearest interactive ancestor (button/a/[role=button]
        // or anything carrying data-sp-*/data-track-id). So wrappers around
        // clickable content still resolve to a meaningful key + data set.
        var hop = t, found = null;
        while (hop && hop !== document) {
          var tag = (hop.tagName || '').toLowerCase();
          var hasSp = hop.getAttribute && (hop.getAttribute('data-sp-action') ||
                                           hop.getAttribute('data-sp-area') ||
                                           hop.getAttribute('data-track-id'));
          if (tag === 'a' || tag === 'button' || tag === 'input' ||
              (hop.getAttribute && (hop.getAttribute('role') === 'button' ||
                                    hop.onclick)) || hasSp) {
            found = hop; break;
          }
          hop = hop.parentNode;
        }
        var target = found || t;
        post({
          kind: 'click',
          key:  key(target),
          tag:  (target.tagName || '').toLowerCase(),
          href: target.href || '',
          url:  location.href,
          data: collectData(target)
        });
      }, true);
      // Single-page apps rewrite URL without reloading. Hook history API +
      // popstate so route changes still emit a navigate event.
      function nav(method){
        var orig = history[method];
        history[method] = function(){
          var r = orig.apply(this, arguments);
          post({ kind: 'navigate', url: location.href });
          return r;
        };
      }
      nav('pushState'); nav('replaceState');
      window.addEventListener('popstate', function(){
        post({ kind: 'navigate', url: location.href });
      });
    })();
    """
}

extension WKWebView {

    /// Swapped in for WKWebView.load(_:). Forwards to the real implementation
    /// (reachable under this same name after exchange), then logs the URL.
    @objc func ut_load(_ request: URLRequest) -> WKNavigation? {
        let nav = self.ut_load(request)
        if let url = request.url?.absoluteString, !url.isEmpty {
            UniTrack.trackWebViewOpen(url)
        }
        return nav
    }

    /// Swapped in for WKWebView.init(frame:configuration:). Wires the inject
    /// script + message handler into the configuration BEFORE calling the real
    /// initializer — WKWebView reads the configuration only at init time, so
    /// post-hoc injection wouldn't work.
    @objc convenience init(ut_frame frame: CGRect, configuration: WKWebViewConfiguration) {
        // Mutate the shared configuration: register the script + handler
        // unless already present (avoids duplicate handlers crash).
        let ucc = configuration.userContentController
        let handlerName = "unitrack"
        // Strip any previously-installed handler so re-attaching the same
        // configuration to a fresh web view doesn't crash with "duplicate
        // message handler". Defensive — apps that build a fresh config each
        // time skip this branch cheaply.
        ucc.removeScriptMessageHandler(forName: handlerName)
        ucc.add(UniTrackWebMessageHandler.shared, name: handlerName)
        let script = WKUserScript(source: UniTrackWebView.injectJS,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        ucc.addUserScript(script)
        // Call the swapped (now original) initializer.
        self.init(ut_frame: frame, configuration: configuration)
    }
}

/// Receives postMessage payloads from the injected JS and routes to UniTrack.
/// Singleton because every WKWebView in the process shares one handler
/// registration — keeps memory + reference graph simple.
final class UniTrackWebMessageHandler: NSObject, WKScriptMessageHandler {
    static let shared = UniTrackWebMessageHandler()
    private override init() { super.init() }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String else { return }
        let url = (body["url"] as? String) ?? ""
        switch kind {
        case "click":
            let key  = (body["key"] as? String) ?? "unknown"
            let tag  = (body["tag"] as? String) ?? ""
            let href = (body["href"] as? String) ?? ""
            var extra: [String: Any] = ["href": href]
            if let data = body["data"] as? [String: Any] {
                // Flatten the per-element data-* set into `extra` so portal
                // sees columns like data_sp_action, data_sp_area, data_sp_extra
                // alongside the click. data-sp-extra was parsed to a JSON
                // object in the inject script — keep it as a nested map.
                for (k, v) in data { extra[k] = v }
            }
            UniTrack.track("click", properties: [
                "element_key": key,
                "screen":      url,
                "class_name":  tag,
                "framework":   "webview",
                "package":     "",
                "extra":       extra,
            ])
        case "navigate":
            UniTrack.track("webview_navigate", properties: ["url": url])
        default:
            break
        }
    }
}
