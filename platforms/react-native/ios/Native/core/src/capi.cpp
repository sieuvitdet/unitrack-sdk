/*
 * Public C API → C++ Tracker bridge.
 * Bindings (Swift / JNI / RN / Flutter) call into these symbols only.
 */

#include "../include/unitrack/unitrack.h"
#include "tracker.h"
#include "config.h"
#include "logger.h"
#include "trace_context.h"

#include <new>
#include <string>
#include <cstring>

#define UT_VERSION_STRING "1.0.0"

using namespace unitrack;

// Opaque struct exposed to C — contains our C++ Tracker.
struct ut_context {
    Tracker* tracker;
};

static const char* safe(const char* s) { return s ? s : ""; }

extern "C" {

ut_context* ut_init(const char* api_key,
                    const char* config_json,
                    ut_platform platform) {
    if (!api_key) return nullptr;
    try {
        Config cfg = Config::from_json(api_key, safe(config_json));
        auto* ctx = new ut_context;
        ctx->tracker = new Tracker(std::move(cfg), platform);
        return ctx;
    } catch (const std::exception& e) {
        UT_LOGE("CAPI", std::string("ut_init failed: ") + e.what());
        return nullptr;
    } catch (...) {
        return nullptr;
    }
}

void ut_flush(ut_context* ctx) {
    if (ctx && ctx->tracker) ctx->tracker->flush_now();
}

void ut_shutdown(ut_context* ctx) {
    if (!ctx) return;
    delete ctx->tracker;
    delete ctx;
}

void ut_identify(ut_context* ctx, const char* user_id, const char* traits_json) {
    if (ctx && ctx->tracker)
        ctx->tracker->identify(safe(user_id), safe(traits_json));
}

void ut_reset(ut_context* ctx) {
    if (ctx && ctx->tracker) ctx->tracker->reset();
}

void ut_track(ut_context* ctx, const char* event_name, const char* properties_json) {
    if (ctx && ctx->tracker && event_name)
        ctx->tracker->track(event_name, safe(properties_json));
}

void ut_set_screen(ut_context* ctx, const char* screen_name) {
    if (ctx && ctx->tracker && screen_name)
        ctx->tracker->set_screen(screen_name);
}

void ut_log_tap(ut_context* ctx, const char* element_key,
                const char* screen, const char* extra_json) {
    if (ctx && ctx->tracker)
        ctx->tracker->log_tap(safe(element_key), safe(screen), safe(extra_json));
}

void ut_log_network(ut_context* ctx, const char* url, const char* method,
                    int status_code, long duration_ms,
                    long request_bytes, long response_bytes,
                    const char* error) {
    if (ctx && ctx->tracker)
        ctx->tracker->log_network(safe(url), safe(method), status_code,
                                  duration_ms, request_bytes, response_bytes,
                                  safe(error));
}

void ut_log_json_error(ut_context* ctx, const char* target_type,
                       const char* error_message, const char* stack_trace,
                       const char* data_preview) {
    if (ctx && ctx->tracker)
        ctx->tracker->log_json_error(safe(target_type), safe(error_message),
                                     safe(stack_trace), safe(data_preview));
}

void ut_log_memory_warning(ut_context* ctx, long memory_used_bytes,
                           long memory_limit_bytes, const char* current_screen) {
    if (ctx && ctx->tracker)
        ctx->tracker->log_memory_warning(memory_used_bytes, memory_limit_bytes,
                                         safe(current_screen));
}

void ut_log_crash(ut_context* ctx, const char* crash_json) {
    if (ctx && ctx->tracker) ctx->tracker->log_crash(safe(crash_json));
}

void ut_log_foreground(ut_context* ctx) {
    if (ctx && ctx->tracker) ctx->tracker->log_foreground();
}

void ut_log_background(ut_context* ctx) {
    if (ctx && ctx->tracker) ctx->tracker->log_background();
}

void ut_log_app_start(ut_context* ctx, long cold_start_ms) {
    if (ctx && ctx->tracker) ctx->tracker->log_app_start(cold_start_ms);
}

void ut_set_log_level(ut_context* /*ctx*/, ut_log_level level) {
    Logger::instance().set_level(level);
}

void ut_set_enabled(ut_context* ctx, int enabled) {
    if (ctx && ctx->tracker) ctx->tracker->set_enabled(enabled != 0);
}

void ut_set_device_info(ut_context* ctx, const char* device_json) {
    if (ctx && ctx->tracker) ctx->tracker->set_device_info(safe(device_json));
}

int ut_is_enabled(ut_context* ctx) {
    return (ctx && ctx->tracker && ctx->tracker->is_enabled()) ? 1 : 0;
}

void ut_set_http_transport(ut_context* ctx, ut_http_send_fn fn, void* user_data) {
    if (ctx && ctx->tracker) ctx->tracker->set_http_transport(fn, user_data);
}

// ── W3C Trace Context bridge ───────────────────────────────────────────────
// Pure helpers — không cần ut_context, để binding gọi được sớm trước khi init
// xong (ví dụ wrap HTTP interceptor cài đặt ở class loader / app delegate).

ut_trace_ids ut_new_trace(void) {
    ut_trace_ids out{};
    auto ids = unitrack::new_trace();
    // Cấu trúc C và C++ trùng layout (cùng kích thước mảng), nên copy bytewise
    // an toàn — tránh phụ thuộc layout-compat giữa POD C và POD C++.
    std::memcpy(out.trace_id, ids.trace_id, sizeof(out.trace_id));
    std::memcpy(out.span_id,  ids.span_id,  sizeof(out.span_id));
    return out;
}

size_t ut_format_traceparent(const ut_trace_ids* ids,
                             int sampled,
                             char* out,
                             size_t out_size) {
    if (!ids || !out || out_size < 56) return 0;  // 55 byte + NUL
    unitrack::TraceIds tmp{};
    std::memcpy(tmp.trace_id, ids->trace_id, sizeof(tmp.trace_id));
    std::memcpy(tmp.span_id,  ids->span_id,  sizeof(tmp.span_id));
    auto s = unitrack::traceparent_header(tmp, sampled != 0);
    // s đúng 55 ký tự. memcpy + NUL, không strncpy (clang warning).
    std::memcpy(out, s.data(), s.size());
    out[s.size()] = '\0';
    return s.size();
}

const char* ut_version(void) {
    return UT_VERSION_STRING;
}

// Returns a pointer the caller must NOT free. The string lives in a thread-local
// buffer; the second call from the same thread overwrites the previous result.
// Empty string ("") on no crash to pop or null ctx.
const char* ut_pop_recovered_crash(ut_context* ctx) {
    thread_local std::string buf;
    if (!ctx || !ctx->tracker) { buf.clear(); return ""; }
    buf = ctx->tracker->pop_recovered_crash();
    return buf.c_str();
}

// Read-only view of the current session id (UUID). Thread-local buffer same
// as ut_pop_recovered_crash. Empty when ctx is null. Used by bindings that
// need to stamp session_id on app-side events (vd iOS session_ended).
const char* ut_current_session_id(ut_context* ctx) {
    thread_local std::string buf;
    if (!ctx || !ctx->tracker) { buf.clear(); return ""; }
    buf = ctx->tracker->current_session_id();
    return buf.c_str();
}

// Lifetime session counter (persists across launches). 1 on first install,
// +1 per timeout rotation. Returns 0 when ctx is null.
int64_t ut_current_session_index(ut_context* ctx) {
    if (!ctx || !ctx->tracker) return 0;
    return ctx->tracker->current_session_index();
}

// UUID of the session that just closed (empty when this is the first session
// after install). Thread-local buffer same convention as ut_current_session_id.
const char* ut_previous_session_id(ut_context* ctx) {
    thread_local std::string buf;
    if (!ctx || !ctx->tracker) { buf.clear(); return ""; }
    buf = ctx->tracker->previous_session_id();
    return buf.c_str();
}

// Force-rotate the active session. Bumps session_index, mints a new UUID,
// stamps the just-closed session as previous_session_id. Bindings call
// this on logout / switch-account / app-level "new context" boundaries —
// the timeout-based rotation handles only inactivity. No-op when ctx is
// null.
void ut_rotate_session(ut_context* ctx) {
    if (!ctx || !ctx->tracker) return;
    ctx->tracker->rotate_session();
}

// Snapshot of pending offline-queued events grouped by event_name. Thread-local
// buffer same convention as the other string getters. Returns "{}" on null ctx
// or empty queue. The JSON shape is {"ev_click":3,"ev_result":2}.
const char* ut_pending_event_counts(ut_context* ctx) {
    thread_local std::string buf;
    if (!ctx || !ctx->tracker) { buf = "{}"; return buf.c_str(); }
    buf = ctx->tracker->pending_event_counts_json();
    return buf.c_str();
}

// Register a flush-success callback. The C function-pointer signature matches
// Tracker::FlushCallback so no shim is needed — straight forward into the
// C++ method. Pass fn=NULL to clear.
void ut_set_flush_callback(ut_context* ctx, ut_flush_success_fn fn, void* userdata) {
    if (!ctx || !ctx->tracker) return;
    ctx->tracker->set_flush_callback(
        reinterpret_cast<unitrack::Tracker::FlushCallback>(fn), userdata);
}

} // extern "C"
