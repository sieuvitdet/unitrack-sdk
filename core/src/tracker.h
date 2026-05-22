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

    void set_enabled(bool e) { enabled_.store(e); }
    bool is_enabled() const  { return enabled_.load(); }

    void set_http_transport(ut_http_send_fn fn, void* ud) {
        transport_.set_callback(fn, ud);
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
    std::string      user_id_;
    std::string      user_traits_json_ = "{}";

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
};

} // namespace unitrack
