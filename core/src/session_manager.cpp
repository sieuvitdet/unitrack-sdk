#include "session_manager.h"
#include "util.h"

namespace unitrack {

SessionManager::SessionManager() {
    rotate_locked();
}

void SessionManager::rotate_locked() {
    session_id_       = generate_uuid();
    last_activity_ms_ = current_time_ms();
}

void SessionManager::rotate() {
    std::lock_guard<std::mutex> lock(mu_);
    rotate_locked();
}

std::string SessionManager::current_session_id() {
    std::lock_guard<std::mutex> lock(mu_);
    int64_t now = current_time_ms();
    if (now - last_activity_ms_ > timeout_ms_) {
        rotate_locked();
    }
    last_activity_ms_ = now;
    return session_id_;
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
