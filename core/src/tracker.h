#pragma once

#include "config.h"
#include "event.h"
#include "offline_queue.h"
#include "transport.h"
#include "session_manager.h"
#include "../include/unitrack/unitrack.h"

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace unitrack {

// The Tracker is the single coordinator for the SDK. It owns the queue,
// transport, session manager, and the background flush thread.
class Tracker {
public:
    Tracker(Config cfg, ut_platform platform);
    ~Tracker();

    Tracker(const Tracker&) = delete;
    Tracker& operator=(const Tracker&) = delete;

    // Hot path — called from any thread.
    void track(const std::string& event_name, const std::string& props_json);
    void set_screen(const std::string& screen_name);
    void identify(const std::string& user_id, const std::string& traits_json);
    void reset();

    // Lightweight read of the active session id — used by bindings that need
    // to stamp session_id onto app-side events (vd iOS session_ended fired
    // from the AppLifecycleObserver after a foreground rotation). Returns ""
    // if no session has been opened yet.
    std::string current_session_id() { return session_.current_session_id(); }

    // Lifetime counter — persists across launches via session.json. 1 on
    // first install, +1 per timeout-driven rotation. Apps read this to stamp
    // event_action=session_started events without managing their own counter.
    int64_t     current_session_index() { return session_.current_session_index(); }

    // UUID of the session that just closed (empty if this is the very first
    // session). Useful for FPT-style session_started payloads that carry
    // previous_session_id so backend can chain consecutive sessions.
    std::string previous_session_id()   { return session_.previous_session_id(); }

    // Force a session rotation right now — bumps session_index, mints a
    // new UUID, records the closed session as previous. Apps call this on
    // logout / switch-account / "new conversation" boundaries when the
    // timeout-based rotation isn't enough. The reason is stamped on the
    // next session_end the SDK fires so analytics can tell timeout from
    // manual rotations apart.
    void rotate_session(SessionEndReason reason = SessionEndReason::manual_reset) {
        session_.rotate(reason);
    }

    // Auto-capture entry points.
    void log_tap(const std::string& element_key,
                 const std::string& screen,
                 const std::string& extra_json);
    void log_network(const std::string& url, const std::string& method,
                     int status, long duration_ms,
                     long req_bytes, long resp_bytes,
                     const std::string& error);
    void log_json_error(const std::string& target_type,
                        const std::string& error_msg,
                        const std::string& stack,
                        const std::string& data_preview);
    void log_memory_warning(long used, long limit, const std::string& screen);
    void log_crash(const std::string& crash_json);
    void log_foreground();
    void log_background();
    void log_app_start(long cold_start_ms);

    // Forces a flush (blocks briefly).
    void flush_now();

    // Snapshot of the offline queue grouped by event_name — used by demo /
    // debug UIs to show "Saved 3 ev_click, 2 ev_result" while offline. Returns
    // a JSON object string: {"ev_click":3,"ev_result":2}. Empty queue → "{}".
    std::string pending_event_counts_json();

    // Flush-success callback. Fires once per do_flush() that lands a batch
    // server-side; payload is the per-event_name breakdown of THAT batch
    // (vd `{"ev_click":3,"ev_result":2}`). Apps wire this to a UIToast so a
    // real-device airplane-mode test shows "Flushed 5 ev_click..." the moment
    // network comes back. Fires on the worker thread — wrappers must hop to
    // main before touching UI. Pass fn=nullptr to clear.
    using FlushCallback = void(*)(const char* counts_json, void* userdata);
    void set_flush_callback(FlushCallback fn, void* userdata) {
        std::lock_guard<std::mutex> lock(state_mu_);
        flush_cb_      = fn;
        flush_cb_data_ = userdata;
    }

    void set_enabled(bool e) { enabled_.store(e); }
    bool is_enabled() const  { return enabled_.load(); }

    // Device/app metadata (model, OS, app version, locale, …) attached to
    // every event. Set once by the platform binding right after init.
    void set_device_info(const std::string& device_json) {
        std::lock_guard<std::mutex> lock(state_mu_);
        device_json_ = device_json.empty() ? "" : device_json;
    }

    void set_http_transport(ut_http_send_fn fn, void* ud) {
        transport_.set_callback(fn, ud);
    }

    // Crash recovered at init() time is enqueued to the offline queue
    // (→ portal HTTP) but bypasses platform providers (Snowplow, Firebase)
    // because those live above the C ABI. Binding code pops the same JSON
    // here after providers init and re-emits it through forEachProvider.
    // Single-shot — second call returns empty.
    std::string pop_recovered_crash() {
        std::lock_guard<std::mutex> lock(state_mu_);
        std::string out = std::move(recovered_crash_json_);
        recovered_crash_json_.clear();
        return out;
    }

private:
    Config           config_;
    ut_platform      platform_;
    OfflineQueue     queue_;
    Transport        transport_;
    SessionManager   session_;

    std::atomic<bool> enabled_{true};
    std::atomic<bool> running_{true};

    std::mutex       state_mu_;
    std::string      current_screen_;
    long long        screen_entered_at_ms_ = 0;  // when current_screen_ was entered (dwell)
    std::string      user_id_;
    std::string      user_traits_json_ = "{}";
    std::string      device_json_;        // device/app metadata, attached to every event
    long long        init_time_ms_ = 0;   // when the tracker initialized (for crash_on_launch)
    std::string      started_session_;    // last session id we emitted session_start for (dedupe)
    std::string      recovered_crash_json_; // popped via pop_recovered_crash() by binding

    // Flush-success notification. Set via set_flush_callback(); fired from the
    // worker thread inside do_flush() after a successful upload. Read under
    // state_mu_ then released before calling so the callback can't deadlock
    // against further track() calls.
    FlushCallback    flush_cb_      = nullptr;
    void*            flush_cb_data_ = nullptr;

    // Window after init within which a crash counts as a "launch crash".
    static constexpr long long kLaunchCrashWindowMs = 5000;

    // Background flush thread
    std::thread              worker_;
    std::mutex               worker_mu_;
    std::condition_variable  worker_cv_;
    bool                     flush_requested_ = false;

    void worker_loop();
    void do_flush();
    bool should_sample();

    Event build_event(const std::string& name, const std::string& props_json);
    void  enqueue(Event&& e);
    static std::string inject_crash_on_launch(const std::string& crash_json, bool on_launch);

    // Session journey boundaries. Resolves the current session and, if it just
    // rotated, emits session_end(prev) + session_start(current). Called at
    // lifecycle edges (app_start, foreground, reset). No-op when journey_capture
    // is off. `on_rotate` attributes a rotation triggered by this call.
    void emit_session_boundary(SessionEndReason on_rotate);
    static const char* session_end_reason_str(SessionEndReason r);
};

} // namespace unitrack
