package com.unitrack.demo

import android.os.Handler
import android.os.Looper
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Request
import okhttp3.Response
import java.io.IOException

/**
 * Fires realistic backend calls so the SDK auto-captures them as
 * `network_request`. Every call goes through [DemoApp.http] (the OkHttp client
 * wrapped by OkHttpTracker.attach), so the SDK records url/method/status/
 * duration with no extra code. Status codes are varied (200/4xx/5xx) so the
 * per-session wireframe shows success vs error.
 *
 * httpbin.org/status/<code> returns that HTTP status; we tack the logical path
 * on as a query so the captured URL is self-describing in the portal.
 */
object DemoApi {

    private val main = Handler(Looper.getMainLooper())

    /** GET a backend "resource" path; status defaults to 200. */
    fun call(path: String, method: String = "GET", status: Int = 200) {
        val url = "https://httpbin.org/status/$status?path=${path.trimStart('/')}"
        val req = Request.Builder().url(url).method(method, emptyBodyIfNeeded(method)).build()
        DemoApp.http.newCall(req).enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {}
            override fun onResponse(call: Call, response: Response) { response.close() }
        })
    }

    /** Fire several calls in sequence with small delays so they read as a flow. */
    fun sequence(calls: List<Triple<String, String, Int>>) {
        calls.forEachIndexed { i, (path, method, status) ->
            main.postDelayed({ call(path, method, status) }, i * 250L)
        }
    }

    // OkHttp requires a body for POST/PUT/etc.; GET/HEAD must have none.
    private fun emptyBodyIfNeeded(method: String) =
        if (method == "GET" || method == "HEAD") null
        else okhttp3.RequestBody.create(null, ByteArray(0))
}
