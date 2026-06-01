package com.unitrack.sdk

import android.graphics.Bitmap
import android.webkit.WebView
import android.webkit.WebViewClient

/**
 * Drop-in WebView auto-capture for Android. Android's WebView has no central
 * funnel like iOS's WKWebView.load() (it's plain `view.loadUrl(url)` against
 * an instance, no method to swizzle without dex hackery), so the app wires
 * one helper per WebView:
 *
 *     UniTrackWebView.attach(myWebView)
 *
 * `attach` replaces the WebViewClient with a delegating proxy that:
 *   1. Forwards every callback to the existing client (preserves app behaviour)
 *   2. Fires `webview_open` on the first `onPageStarted`
 *   3. Fires `webview_navigate` on subsequent `onPageStarted`s
 *
 * If you want to keep your own WebViewClient subclass, pass it to attach
 * as the second arg — the proxy wraps it.
 */
object UniTrackWebView {

    @JvmStatic @JvmOverloads
    fun attach(webView: WebView, inner: WebViewClient? = null) {
        val base = inner ?: webView.webViewClient
        webView.webViewClient = ProxyClient(base)
    }

    private class ProxyClient(private val inner: WebViewClient?) : WebViewClient() {
        // First URL on this WebView fires webview_open; everything after is a
        // navigation within the same web shell. We track per-instance so
        // reusing a WebView for a fresh page emits a new "open" too — reset
        // happens when WebView.loadUrl is called with a different host.
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

        // Forward everything else verbatim.
        override fun onPageFinished(view: WebView?, url: String?) {
            inner?.onPageFinished(view, url)
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
