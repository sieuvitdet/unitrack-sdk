package com.unitrack.sdk

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject

/**
 * Drop-in WebView auto-capture for Android.
 *
 * Two surfaces are observed:
 *   1. The native WebView client — fires `webview_open` on first URL load
 *      and `webview_navigate` on subsequent loads (host change → new "open").
 *   2. An injected JavaScript that hooks `document.click` and history
 *      pushState/replaceState/popstate. The JS posts events back through a
 *      JavascriptInterface so the portal sees in-page clicks + SPA route
 *      changes as `click` (framework=webview) and `webview_navigate` events.
 *
 * Android can't swizzle WebView.loadUrl() cleanly (no global funnel like
 * iOS WKWebView), so the app wires one helper per WebView at construction:
 *
 *     UniTrackWebView.attach(myWebView)
 *
 * If the app already has its own WebViewClient subclass, pass it as the
 * second arg — the proxy wraps it. Existing JavascriptInterface bindings
 * are preserved (we add ours alongside).
 */
object UniTrackWebView {

    private const val BRIDGE_NAME = "UniTrackBridge"

    /** Inject script — same shape + idempotency as the iOS version so the
     *  payload format matches. Sends JSON-encoded strings to the native
     *  bridge because JavascriptInterface only accepts primitives. */
    private val INJECT_JS = """
    (function(){
      if (window.__unitrack && window.__unitrack.installed) return;
      window.__unitrack = { installed: true };
      function key(el){
        if (!el) return 'unknown';
        var k = el.getAttribute && (el.getAttribute('data-track-id') ||
                                    el.getAttribute('data-testid') ||
                                    el.id ||
                                    el.getAttribute('aria-label'));
        if (k) return String(k).slice(0, 80);
        var tag = (el.tagName || '').toLowerCase();
        var txt = (el.innerText || el.textContent || '').trim().replace(/\s+/g, ' ');
        if (txt) return tag + ':' + txt.slice(0, 60);
        return tag || 'unknown';
      }
      function post(payload){
        try { ${BRIDGE_NAME}.postMessage(JSON.stringify(payload)); } catch(e) {}
      }
      document.addEventListener('click', function(ev){
        var t = ev.target, hop = t, found = null;
        while (hop && hop !== document) {
          var tag = (hop.tagName || '').toLowerCase();
          if (tag === 'a' || tag === 'button' || tag === 'input' ||
              (hop.getAttribute && (hop.getAttribute('role') === 'button' ||
                                    hop.getAttribute('data-track-id') ||
                                    hop.onclick))) {
            found = hop; break;
          }
          hop = hop.parentNode;
        }
        var target = found || t;
        post({ kind: 'click', key: key(target),
               tag: (target.tagName || '').toLowerCase(),
               href: target.href || '', url: location.href });
      }, true);
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
    """.trimIndent()

    @SuppressLint("SetJavaScriptEnabled", "AddJavascriptInterface")
    @JvmStatic @JvmOverloads
    fun attach(webView: WebView, inner: WebViewClient? = null) {
        // Inject script + bridge needs JS enabled. We only flip it on,
        // never off — the app might rely on it being on already.
        webView.settings.javaScriptEnabled = true
        // Bridge: routes JS postMessage payloads to UniTrack.track. The
        // interface name "UniTrackBridge" matches what INJECT_JS calls.
        // Idempotent — calling addJavascriptInterface with the same name
        // just replaces the previous binding.
        webView.addJavascriptInterface(JsBridge, BRIDGE_NAME)
        // Wrap the existing client (or current one) so first-page-load +
        // post-load JS injection both fire while delegating everything else.
        val base = inner ?: webView.webViewClient
        webView.webViewClient = ProxyClient(base)
    }

    /** Receives JSON payloads from the injected JS. Annotated
     *  @JavascriptInterface so WebView allows JS → Java calls. */
    internal object JsBridge {
        @JavascriptInterface
        fun postMessage(json: String) {
            try {
                val o = JSONObject(json)
                val kind = o.optString("kind")
                val url  = o.optString("url")
                when (kind) {
                    "click" -> {
                        val key  = o.optString("key", "unknown")
                        val tag  = o.optString("tag", "")
                        val href = o.optString("href", "")
                        UniTrack.track("click", mapOf(
                            "element_key" to key,
                            "screen"      to url,
                            "class_name"  to tag,
                            "framework"   to "webview",
                            "package"     to "",
                            "extra"       to mapOf("href" to href),
                        ))
                    }
                    "navigate" -> {
                        UniTrack.track("webview_navigate", mapOf("url" to url))
                    }
                }
            } catch (_: Throwable) { /* defensive: never break the WebView */ }
        }
    }

    private class ProxyClient(private val inner: WebViewClient?) : WebViewClient() {
        @Volatile private var firstHost: String? = null

        override fun onPageStarted(view: WebView?, url: String?, favicon: Bitmap?) {
            inner?.onPageStarted(view, url, favicon)
            if (url.isNullOrEmpty()) return
            val host = runCatching { android.net.Uri.parse(url).host }.getOrNull()
            val current = firstHost
            if (current == null || current != host) {
                firstHost = host
                UniTrack.trackWebViewOpen(url)
            } else {
                UniTrack.track("webview_navigate", mapOf("url" to url))
            }
        }

        override fun onPageFinished(view: WebView?, url: String?) {
            inner?.onPageFinished(view, url)
            // Inject the tracking script after the DOM is ready. WebView
            // ignores eval'd code if injected too early on some Android
            // versions; onPageFinished is the safest hook. The script's
            // own idempotency guard (window.__unitrack.installed) prevents
            // double-registration on history-driven re-fires.
            view?.evaluateJavascript(INJECT_JS, null)
        }

        override fun onReceivedError(view: WebView?, request: android.webkit.WebResourceRequest?,
                                     error: android.webkit.WebResourceError?) {
            inner?.onReceivedError(view, request, error)
        }
        override fun shouldOverrideUrlLoading(view: WebView?,
                                              request: android.webkit.WebResourceRequest?): Boolean =
            inner?.shouldOverrideUrlLoading(view, request) ?: false
    }
}
