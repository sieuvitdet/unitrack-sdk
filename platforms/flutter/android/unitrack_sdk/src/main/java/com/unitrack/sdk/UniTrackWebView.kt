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
     *  bridge because JavascriptInterface only accepts primitives.
     *
     *  Resolves element_key from data-sp-action → data-track-id → title → id
     *  → aria-label → tag:text, and harvests every data-* (incl. parsed
     *  data-sp-extra JSON) into the `data` map so portal-side filtering can
     *  match on any attribute. */
    private val INJECT_JS = """
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
        var txt = (el.innerText || el.textContent || '').trim().replace(/\s+/g, ' ');
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
        try { ${BRIDGE_NAME}.postMessage(JSON.stringify(payload)); } catch(e) {}
      }
      document.addEventListener('click', function(ev){
        var t = ev.target, hop = t, found = null;
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
        post({ kind: 'click', key: key(target),
               tag: (target.tagName || '').toLowerCase(),
               href: target.href || '', url: location.href,
               data: collectData(target) });
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
                        // Flatten the per-element data-* set into `extra` so
                        // portal sees columns like data_sp_action, data_sp_area,
                        // data_sp_extra alongside the click. data-sp-extra was
                        // parsed to a JSON object in the inject script — keep
                        // it as a nested map.
                        val extra = mutableMapOf<String, Any>("href" to href)
                        o.optJSONObject("data")?.let { data ->
                            val keys = data.keys()
                            while (keys.hasNext()) {
                                val k = keys.next()
                                val v = data.opt(k) ?: continue
                                extra[k] = jsonToNative(v)
                            }
                        }
                        UniTrack.track("click", mapOf(
                            "element_key" to key,
                            "screen"      to url,
                            "class_name"  to tag,
                            "framework"   to "webview",
                            "package"     to "",
                            "extra"       to extra,
                        ))
                    }
                    "navigate" -> {
                        UniTrack.track("webview_navigate", mapOf("url" to url))
                    }
                }
            } catch (_: Throwable) { /* defensive: never break the WebView */ }
        }

        /** Recursively convert org.json containers to Kotlin Map/List so the
         *  downstream Snowplow/portal serializer sees plain Java types, not
         *  JSONObject/JSONArray (which would otherwise be stringified). */
        private fun jsonToNative(value: Any?): Any {
            return when (value) {
                null, org.json.JSONObject.NULL -> ""
                is org.json.JSONObject -> {
                    val map = mutableMapOf<String, Any>()
                    val keys = value.keys()
                    while (keys.hasNext()) {
                        val k = keys.next()
                        map[k] = jsonToNative(value.opt(k))
                    }
                    map
                }
                is org.json.JSONArray -> {
                    val list = mutableListOf<Any>()
                    for (i in 0 until value.length()) list.add(jsonToNative(value.opt(i)))
                    list
                }
                else -> value
            }
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
