#include "session_manager.h"
#include "util.h"

namespace unitrack {

SessionManager::SessionManager() {
    // First session of the process — no previous session to close.
    session_id_       = generate_uuid();
    started_at_ms_    = current_time_ms();
    last_activity_ms_ = started_at_ms_;
}

void SessionManager::rotate_locked(SessionEndReason reason) {
    int64_t now = current_time_ms();
    // Record the session being closed so the next resolve() can emit a clean
    // session_end/start pair. If a boundary is already pending (rotated twice
    // before anyone resolved), keep the earliest prev_id but update the end —
    // we only emit one boundary, attributing it to the latest reason.
    if (!pending_boundary_) {
        prev_id_         = session_id_;
        prev_started_ms_ = started_at_ms_;
    }
    prev_ended_ms_    = now;
    prev_reason_      = reason;
    pending_boundary_ = true;

    session_id_       = generate_uuid();
    started_at_ms_    = now;
    last_activity_ms_ = now;
}

void SessionManager::rotate(SessionEndReason reason) {
    std::lock_guard<std::mutex> lock(mu_);
    rotate_locked(reason);
}

std::string SessionManager::current_session_id() {
    std::lock_guard<std::mutex> lock(mu_);
    int64_t now = current_time_ms();
    if (now - last_activity_ms_ > timeout_ms_) {
        rotate_locked(SessionEndReason::timeout);
    }
    last_activity_ms_ = now;
    return session_id_;
}

SessionResolution SessionManager::resolve(SessionEndReason on_rotate) {
    std::lock_guard<std::mutex> lock(mu_);
    int64_t now = current_time_ms();
    if (now - last_activity_ms_ > timeout_ms_) {
        rotate_locked(on_rotate);
    }
    last_activity_ms_ = now;

    SessionResolution r;
    r.id            = session_id_;
    r.started_at_ms = started_at_ms_;
    r.rotated       = pending_boundary_;
    if (pending_boundary_) {
        r.prev_id         = prev_id_;
        r.prev_started_ms = prev_started_ms_;
        r.prev_ended_ms   = prev_ended_ms_;
        r.prev_reason     = prev_reason_;
        // Consume the pending boundary — it is now the caller's job to emit it.
        pending_boundary_ = false;
        prev_reason_      = SessionEndReason::none;
    }
    return r;
}

void SessionManager::mark_activity() {
    std::lock_guard<std::mutex> lock(mu_);
    last_activity_ms_ = current_time_ms();
}

void SessionManager::set_timeout_ms(int64_t ms) {
    std::lock_guard<std::mutex> lock(mu_);
    timeout_ms_ = ms;
}

} // namespace unitrack
