/*
 * JNI bridge — converts JNI calls from NativeBridge.kt into core C API
 * calls. Each method does:
 *   1. Pull jstring → C UTF-8 string with GetStringUTFChars
 *   2. Call ut_* from libunitrack
 *   3. Release the JNI string
 *
 * The Kotlin side holds the ut_context as a `Long` (cast pointer).
 */

#include <jni.h>
#include <cstdint>
#include <cstring>
#include <mutex>
#include "unitrack/unitrack.h"

static inline ut_context* ctx_of(jlong p) {
    return reinterpret_cast<ut_context*>(static_cast<uintptr_t>(p));
}

// ── HTTP transport callback ─────────────────────────────────────────────────
// The core is built without libcurl, so it calls this C function to upload each
// batch. We bounce up to Kotlin (NativeBridge.httpPost) which uses
// HttpURLConnection.
//
// IMPORTANT: the callback runs on the core's flush thread, which we attach to
// the JVM. A thread attached this way uses the SYSTEM classloader, so
// FindClass() there CANNOT see app classes (→ ClassNotFoundException). We must
// resolve the class on JNI_OnLoad (which runs on a thread that has the app
// classloader) and cache it as a global ref.
static JavaVM*    g_vm = nullptr;
static jclass     g_bridgeCls = nullptr;   // global ref to NativeBridge
static jmethodID  g_httpPostMid = nullptr;

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
    g_vm = vm;
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    jclass local = env->FindClass("com/unitrack/sdk/bridge/NativeBridge");
    if (local) {
        g_bridgeCls = static_cast<jclass>(env->NewGlobalRef(local));
        g_httpPostMid = env->GetStaticMethodID(
            g_bridgeCls, "httpPost", "(Ljava/lang/String;Ljava/lang/String;[B)I");
        env->DeleteLocalRef(local);
    }
    return JNI_VERSION_1_6;
}

static int ut_android_http_send(const char* url, const char* /*method*/,
                                const char* headers, const char* body,
                                size_t body_len, void* /*user_data*/) {
    if (!g_vm || !g_bridgeCls || !g_httpPostMid) return 0;
    JNIEnv* env = nullptr;
    bool attached = false;
    if (g_vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        if (g_vm->AttachCurrentThread(&env, nullptr) != JNI_OK) return 0;
        attached = true;
    }
    jstring jurl  = env->NewStringUTF(url ? url : "");
    jstring jhdrs = env->NewStringUTF(headers ? headers : "{}");
    jbyteArray jbody = env->NewByteArray(static_cast<jsize>(body_len));
    if (jbody && body_len > 0)
        env->SetByteArrayRegion(jbody, 0, static_cast<jsize>(body_len),
                                reinterpret_cast<const jbyte*>(body));
    int status = env->CallStaticIntMethod(g_bridgeCls, g_httpPostMid, jurl, jhdrs, jbody);
    if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); status = 0; }
    env->DeleteLocalRef(jurl);
    env->DeleteLocalRef(jhdrs);
    if (jbody) env->DeleteLocalRef(jbody);
    if (attached) g_vm->DetachCurrentThread();
    return status;
}

// Helper: scoped UTF-8 C string from jstring.
namespace {
struct JStr {
    JNIEnv* env;
    jstring j;
    const char* s;
    JStr(JNIEnv* e, jstring js) : env(e), j(js),
        s(js ? e->GetStringUTFChars(js, nullptr) : nullptr) {}
    ~JStr() { if (s && j) env->ReleaseStringUTFChars(j, s); }
    const char* c() const { return s ? s : ""; }
};
}

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeInit(
    JNIEnv* env, jobject /*self*/,
    jstring apiKey, jstring cfg, jint platform)
{
    JStr k(env, apiKey), c(env, cfg);
    ut_context* ctx = ut_init(k.c(), c.c(), (ut_platform)platform);
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(ctx));
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeInstallHttp(
    JNIEnv*, jobject, jlong p)
{
    ut_set_http_transport(ctx_of(p), ut_android_http_send, nullptr);
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeShutdown(
    JNIEnv*, jobject, jlong p) { ut_shutdown(ctx_of(p)); }

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeFlush(
    JNIEnv*, jobject, jlong p) { ut_flush(ctx_of(p)); }

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeIdentify(
    JNIEnv* env, jobject, jlong p, jstring uid, jstring traits)
{
    JStr u(env, uid), t(env, traits);
    ut_identify(ctx_of(p), u.c(), t.c());
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeReset(
    JNIEnv*, jobject, jlong p) { ut_reset(ctx_of(p)); }

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeTrack(
    JNIEnv* env, jobject, jlong p, jstring ev, jstring props)
{
    JStr e(env, ev), pr(env, props);
    ut_track(ctx_of(p), e.c(), pr.c());
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeSetScreen(
    JNIEnv* env, jobject, jlong p, jstring name)
{
    JStr n(env, name);
    ut_set_screen(ctx_of(p), n.c());
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeSetEnabled(
    JNIEnv*, jobject, jlong p, jboolean on)
{
    ut_set_enabled(ctx_of(p), on ? 1 : 0);
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeSetDeviceInfo(
    JNIEnv* env, jobject, jlong p, jstring deviceJson)
{
    JStr d(env, deviceJson);
    ut_set_device_info(ctx_of(p), d.c());
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeLogTap(
    JNIEnv* env, jobject, jlong p, jstring key, jstring scr, jstring extra)
{
    JStr k(env, key), s(env, scr), x(env, extra);
    ut_log_tap(ctx_of(p), k.c(), s.c(), x.c());
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeLogNetwork(
    JNIEnv* env, jobject, jlong p, jstring url, jstring method, jint status,
    jlong dur, jlong req_bytes, jlong resp_bytes, jstring err)
{
    JStr u(env, url), m(env, method), e(env, err);
    ut_log_network(ctx_of(p), u.c(), m.c(), status,
                   (long)dur, (long)req_bytes, (long)resp_bytes, e.c());
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeLogJsonError(
    JNIEnv* env, jobject, jlong p, jstring t, jstring err, jstring stk, jstring prev)
{
    JStr tt(env, t), e(env, err), s(env, stk), pv(env, prev);
    ut_log_json_error(ctx_of(p), tt.c(), e.c(), s.c(), pv.c());
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeLogMemoryWarning(
    JNIEnv* env, jobject, jlong p, jlong used, jlong limit, jstring scr)
{
    JStr s(env, scr);
    ut_log_memory_warning(ctx_of(p), (long)used, (long)limit, s.c());
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeLogCrash(
    JNIEnv* env, jobject, jlong p, jstring crash)
{
    JStr c(env, crash);
    ut_log_crash(ctx_of(p), c.c());
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeLogForeground(
    JNIEnv*, jobject, jlong p) { ut_log_foreground(ctx_of(p)); }

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeLogBackground(
    JNIEnv*, jobject, jlong p) { ut_log_background(ctx_of(p)); }

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeLogAppStart(
    JNIEnv*, jobject, jlong p, jlong ms) { ut_log_app_start(ctx_of(p), (long)ms); }

// Pop the JSON the core stashed at init() from crash-pending.json. UniTrack.kt
// calls this AFTER providers init and fans out the crash via forEachProvider
// so Snowplow / Firebase see the recovered crash through their own track()
// paths (the C++ track() inside ut_init only reaches the offline queue).
// Returns "" when nothing to pop. Single-shot.
JNIEXPORT jstring JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativePopRecoveredCrash(
    JNIEnv* env, jobject, jlong p) {
    const char* s = ut_pop_recovered_crash(ctx_of(p));
    return env->NewStringUTF(s ? s : "");
}

// W3C distributed tracing — mint a (trace_id, span_id) pair for the calling
// HTTP request. Returns a length-2 String[] {traceId, spanId}, both already
// lowercase hex. The core helper is pure and doesn't touch ut_context — keep
// it that way here too so Kotlin can call this from an OkHttp interceptor
// installed in Application.onCreate, before UniTrack.init finishes.
JNIEXPORT jobjectArray JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeNewTrace(JNIEnv* env, jobject) {
    ut_trace_ids ids = ut_new_trace();
    jclass strCls = env->FindClass("java/lang/String");
    jobjectArray out = env->NewObjectArray(2, strCls, nullptr);
    // Release the class local ref now that NewObjectArray captured it; the
    // jstrings get the same treatment after SetObjectArrayElement copies the
    // ref into the array. Per-call cleanup keeps the local-ref table from
    // ballooning when callers invoke this in a tight OkHttp interceptor loop.
    env->DeleteLocalRef(strCls);
    jstring s0 = env->NewStringUTF(ids.trace_id);
    jstring s1 = env->NewStringUTF(ids.span_id);
    env->SetObjectArrayElement(out, 0, s0);
    env->SetObjectArrayElement(out, 1, s1);
    env->DeleteLocalRef(s0);
    env->DeleteLocalRef(s1);
    return out;
}

// ── Session API (iOS parity: currentSessionId / sessionIndex / previousSessionId / rotate) ─
//
// Core already persists session_id + session_index + previous_session_id
// across app launches via session.json. These bridges just expose those
// values to Kotlin so apps don't maintain a duplicate (resetting-to-0)
// counter on the binding side.

JNIEXPORT jstring JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeCurrentSessionId(
    JNIEnv* env, jobject, jlong p) {
    const char* s = ut_current_session_id(ctx_of(p));
    return env->NewStringUTF(s ? s : "");
}

JNIEXPORT jlong JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeSessionIndex(
    JNIEnv* /*env*/, jobject, jlong p) {
    return static_cast<jlong>(ut_current_session_index(ctx_of(p)));
}

JNIEXPORT jstring JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativePreviousSessionId(
    JNIEnv* env, jobject, jlong p) {
    const char* s = ut_previous_session_id(ctx_of(p));
    return env->NewStringUTF(s ? s : "");
}

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeRotateSession(
    JNIEnv* /*env*/, jobject, jlong p) {
    ut_rotate_session(ctx_of(p));
}

JNIEXPORT jstring JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativePendingEventCounts(
    JNIEnv* env, jobject, jlong p) {
    const char* s = ut_pending_event_counts(ctx_of(p));
    return env->NewStringUTF(s ? s : "{}");
}

// ─── flush-success callback ─────────────────────────────────────────────────
// One JVM-side listener is stored as a global ref. The C callback runs on the
// SDK worker thread, attaches the current native thread to the JVM (Android
// worker threads aren't auto-attached), then calls the listener's onFlushed.
// Pass listener=null to clear.

namespace {

static jobject     g_flush_listener   = nullptr;   // global ref to Kotlin lambda holder
static jmethodID   g_flush_listener_m = nullptr;   // FlushListener.onFlushed(String)
static JavaVM*     g_vm_for_flush     = nullptr;
// Guards swap-of and read-of g_flush_listener / g_flush_listener_m. The setter
// runs on the JVM caller thread; the thunk runs on the core worker thread.
// Without this lock a swap during nativeSetFlushListener can DeleteGlobalRef
// the very jobject the thunk is about to CallVoidMethod on → use-after-free.
static std::mutex  g_flush_mu;

extern "C" void unitrack_flush_thunk(const char* counts_json, void* /*ud*/) {
    if (!g_vm_for_flush) return;
    JNIEnv* env = nullptr;
    bool detach = false;
    jint st = g_vm_for_flush->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6);
    if (st == JNI_EDETACHED) {
        if (g_vm_for_flush->AttachCurrentThread(&env, nullptr) != 0) return;
        detach = true;
    } else if (st != JNI_OK || !env) {
        return;
    }
    {
        std::lock_guard<std::mutex> lk(g_flush_mu);
        if (!g_flush_listener || !g_flush_listener_m) {
            if (detach) g_vm_for_flush->DetachCurrentThread();
            return;
        }
        jstring js = env->NewStringUTF(counts_json ? counts_json : "{}");
        env->CallVoidMethod(g_flush_listener, g_flush_listener_m, js);
        if (env->ExceptionCheck()) { env->ExceptionDescribe(); env->ExceptionClear(); }
        env->DeleteLocalRef(js);
    }
    if (detach) g_vm_for_flush->DetachCurrentThread();
}

} // namespace

JNIEXPORT void JNICALL
Java_com_unitrack_sdk_bridge_NativeBridge_nativeSetFlushListener(
    JNIEnv* env, jobject, jlong p, jobject listener) {
    // See g_flush_mu declaration above — hold across the swap so a concurrent
    // unitrack_flush_thunk on the worker thread never sees a freed jobject.
    {
        std::lock_guard<std::mutex> lk(g_flush_mu);
        if (g_flush_listener) {
            env->DeleteGlobalRef(g_flush_listener);
            g_flush_listener   = nullptr;
            g_flush_listener_m = nullptr;
        }
    }
    ut_context* ctx = ctx_of(p);
    if (!ctx) return;

    if (!listener) {
        ut_set_flush_callback(ctx, nullptr, nullptr);
        return;
    }

    env->GetJavaVM(&g_vm_for_flush);
    jobject  newRef = env->NewGlobalRef(listener);
    jclass   cls    = env->GetObjectClass(newRef);
    jmethodID mid   = env->GetMethodID(cls, "onFlushed", "(Ljava/lang/String;)V");
    env->DeleteLocalRef(cls);
    if (!mid) {
        env->DeleteGlobalRef(newRef);
        return;
    }
    {
        std::lock_guard<std::mutex> lk(g_flush_mu);
        g_flush_listener   = newRef;
        g_flush_listener_m = mid;
    }
    ut_set_flush_callback(ctx, &unitrack_flush_thunk, nullptr);
}

} // extern "C"
