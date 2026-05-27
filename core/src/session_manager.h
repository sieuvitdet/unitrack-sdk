#pragma once

#include <atomic>
#include <mutex>
#include <string>

namespace unitrack {

// Why a session rotated — surfaced so the Tracker can emit a matching
// session_end with the right reason. "none" means no rotation happened.
enum class SessionEndReason {
    none,
    timeout,             // inactivity/background exceeded the session timeout
    manual_reset,        // identify reset() / explicit rotate()
};

// Snapshot returned when resolving the current session. If `rotated` is true,
// a new session has just begun and `prev_*` describe the session that closed —
// the Tracker uses this to emit session_end(prev) + session_start(current).
struct SessionResolution {
    std::string id;            // current (possibly new) session id
    int64_t     started_at_ms; // when the current session started
    bool        rotated;       // true if this call started a new session
    std::string      prev_id;        // closed session id (valid when rotated)
    int64_t          prev_started_ms; // closed session start (valid when rotated)
    int64_t          prev_ended_ms;   // closed session end   (valid when rotated)
    SessionEndReason prev_reason;     // why the previous session closed
};

class SessionManager {
public:
    SessionManager();

    // Returns the current session id, starting a new one if the timeout
    // elapsed. Does NOT report rotation — use resolve() when you need to emit
    // session boundaries. Kept for hot-path callers that only need the id.
    std::string current_session_id();

    // Resolve the current session and report whether it just rotated (and why).
    // Pass the reason to attribute to a rotation triggered by this call.
    SessionResolution resolve(SessionEndReason on_rotate = SessionEndReason::timeout);

    // Mark activity — extends the current session.
    void mark_activity();

    // Force start a new session (e.g. on app foreground after long bg, or
    // identify reset). The next resolve() reports the rotation with `reason`.
    void rotate(SessionEndReason reason = SessionEndReason::manual_reset);

    void set_timeout_ms(int64_t ms);

private:
    std::mutex     mu_;
    std::string    session_id_;
    int64_t        started_at_ms_    = 0;
    int64_t        last_activity_ms_ = 0;
    int64_t        timeout_ms_       = 30 * 60 * 1000;  // 30 min default

    // Pending boundary, set when a rotation occurs, consumed by the next
    // resolve(). Lets a timeout-driven rotation (detected mid hot-path) still
    // surface a clean session_end/start pair on the next lifecycle resolve.
    bool             pending_boundary_ = false;
    std::string      prev_id_;
    int64_t          prev_started_ms_ = 0;
    int64_t          prev_ended_ms_   = 0;
    SessionEndReason prev_reason_     = SessionEndReason::none;

    // Rotate, recording the closed session into the pending-boundary fields.
    void rotate_locked(SessionEndReason reason);
};

} // namespace unitrack
