#pragma once

#include <atomic>
#include <mutex>
#include <string>

namespace unitrack {

class SessionManager {
public:
    SessionManager();

    // Returns the current session id, starting a new one if needed.
    std::string current_session_id();

    // Mark activity — extends the current session.
    void mark_activity();

    // Force start a new session (e.g. on app foreground after long bg).
    void rotate();

    void set_timeout_ms(int64_t ms);

private:
    std::mutex     mu_;
    std::string    session_id_;
    int64_t        last_activity_ms_ = 0;
    int64_t        timeout_ms_       = 30 * 60 * 1000;  // 30 min default

    void rotate_locked();
};

} // namespace unitrack
