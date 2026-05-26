/*
 * UniTrack SDK — Public C API
 *
 * This header defines the ABI-stable C interface used by all platform
 * bindings (iOS Swift, Android Kotlin/JNI, React Native, Flutter).
 *
 * All inputs are UTF-8 strings. JSON inputs are validated; invalid JSON
 * is dropped silently and an internal error event is logged.
 */

#ifndef UNITRACK_H
#define UNITRACK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
  #define UT_EXPORT __declspec(dllexport)
#else
  #define UT_EXPORT __attribute__((visibility("default")))
#endif

/* Opaque context. One per app. */
typedef struct ut_context ut_context;

/* Log levels for internal SDK logging. */
typedef enum {
    UT_LOG_ERROR = 0,
    UT_LOG_WARN  = 1,
    UT_LOG_INFO  = 2,
    UT_LOG_DEBUG = 3
} ut_log_level;

/* Platform identifier — set by binding at init time. */
typedef enum {
    UT_PLATFORM_IOS          = 1,
    UT_PLATFORM_ANDROID      = 2,
    UT_PLATFORM_REACT_NATIVE = 3,
    UT_PLATFORM_FLUTTER      = 4
} ut_platform;

/* ============================================================
 * Lifecycle
 * ============================================================ */

/*
 * Initialize the SDK. Must be called exactly once at app startup.
 *
 * @param api_key       Partner API key. Required.
 * @param config_json   JSON config string. May be NULL for defaults.
 *                      Example: {"endpoint":"https://...","sampling":1.0,
 *                                "batch_size":50,"flush_interval_ms":5000,
 *                                "db_path":"/path/to/queue.db"}
 * @param platform      Platform enum.
 * @return              Context pointer, or NULL on failure.
 */
UT_EXPORT ut_context* ut_init(const char* api_key,
                              const char* config_json,
                              ut_platform platform);

/* Flush queued events to network. Blocks briefly. */
UT_EXPORT void ut_flush(ut_context* ctx);

/* Shutdown — flush + release resources. */
UT_EXPORT void ut_shutdown(ut_context* ctx);

/* ============================================================
 * User identity
 * ============================================================ */

UT_EXPORT void ut_identify(ut_context* ctx,
                           const char* user_id,
                           const char* traits_json);

UT_EXPORT void ut_reset(ut_context* ctx);

/* ============================================================
 * Event tracking
 * ============================================================ */

UT_EXPORT void ut_track(ut_context* ctx,
                        const char* event_name,
                        const char* properties_json);

/* Update current screen — called by auto-capture binding. */
UT_EXPORT void ut_set_screen(ut_context* ctx, const char* screen_name);

/* ============================================================
 * Auto-capture hooks (called by platform bindings)
 * ============================================================ */

/* Tap / click event. element_key is the resolved key:
 * accessibilityIdentifier > tag > className.method */
UT_EXPORT void ut_log_tap(ut_context* ctx,
                          const char* element_key,
                          const char* screen,
                          const char* extra_json);

/* Network request completed. */
UT_EXPORT void ut_log_network(ut_context* ctx,
                              const char* url,
                              const char* method,
                              int   status_code,
                              long  duration_ms,
                              long  request_bytes,
                              long  response_bytes,
                              const char* error);

/* JSON parse / decode failure. */
UT_EXPORT void ut_log_json_error(ut_context* ctx,
                                 const char* target_type,
                                 const char* error_message,
                                 const char* stack_trace,
                                 const char* data_preview);

/* Memory warning / pressure event. */
UT_EXPORT void ut_log_memory_warning(ut_context* ctx,
                                     long memory_used_bytes,
                                     long memory_limit_bytes,
                                     const char* current_screen);

/* Crash / fatal — called from signal handler or uncaught exception. */
UT_EXPORT void ut_log_crash(ut_context* ctx, const char* crash_json);

/* App lifecycle */
UT_EXPORT void ut_log_foreground(ut_context* ctx);
UT_EXPORT void ut_log_background(ut_context* ctx);
UT_EXPORT void ut_log_app_start(ut_context* ctx, long cold_start_ms);

/* ============================================================
 * Configuration
 * ============================================================ */

UT_EXPORT void ut_set_log_level(ut_context* ctx, ut_log_level level);
UT_EXPORT void ut_set_enabled(ut_context* ctx, int enabled);
UT_EXPORT int  ut_is_enabled(ut_context* ctx);

/* Set device/app metadata (a JSON object string) attached to every event.
 * Called once by the platform binding right after init. Example:
 *   {"os":"iOS","os_version":"17.4","model":"iPhone15,2",
 *    "app_version":"1.0.0","locale":"vi_VN","sdk_version":"1.0.0"} */
UT_EXPORT void ut_set_device_info(ut_context* ctx, const char* device_json);

/* HTTP transport callback — bindings inject platform HTTP client.
 * If NULL, core uses built-in libcurl. */
typedef int (*ut_http_send_fn)(const char* url,
                               const char* method,
                               const char* headers_json,
                               const char* body,
                               size_t body_len,
                               void* user_data);
UT_EXPORT void ut_set_http_transport(ut_context* ctx,
                                     ut_http_send_fn fn,
                                     void* user_data);

/* SDK version */
UT_EXPORT const char* ut_version(void);

#ifdef __cplusplus
}
#endif

#endif /* UNITRACK_H */
