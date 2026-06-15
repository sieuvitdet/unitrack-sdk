#include "session_manager.h"
#include "util.h"

#include <fstream>
#include <sstream>

namespace unitrack {

SessionManager::SessionManager() {
    // First session of the process — no previous session to close.
    // load_from() may overwrite these if a persisted state exists & is fresh.
    session_id_       = generate_uuid();
    tracking_id_      = generate_uuid();
    started_at_ms_    = current_time_ms();
    last_activity_ms_ = started_at_ms_;
}

// Tiny JSON reader for the 5 keys we persist. We avoid pulling in a JSON dep
// here because the core is meant to compile with just sqlite3 + libc++; the
// state file is internal and always shaped the same way.
//
// Format on disk:
//   {"session_id":"...","session_index":12,"last_activity_ms":1700000,
//    "started_at_ms":1700000,"previous_session_id":"..."}
static std::string read_str_field(const std::string& blob, const std::string& key) {
    std::string needle = "\"" + key + "\":\"";
    auto p = blob.find(needle);
    if (p == std::string::npos) return "";
    p += needle.size();
    auto q = blob.find('"', p);
    if (q == std::string::npos) return "";
    return blob.substr(p, q - p);
}
static int64_t read_int_field(const std::string& blob, const std::string& key) {
    std::string needle = "\"" + key + "\":";
    auto p = blob.find(needle);
    if (p == std::string::npos) return 0;
    p += needle.size();
    // Skip whitespace
    while (p < blob.size() && (blob[p] == ' ' || blob[p] == '\t')) ++p;
    int64_t out = 0;
    int sign = 1;
    if (p < blob.size() && blob[p] == '-') { sign = -1; ++p; }
    while (p < blob.size() && blob[p] >= '0' && blob[p] <= '9') {
        out = out * 10 + (blob[p] - '0');
        ++p;
    }
    return sign * out;
}

void SessionManager::load_from(const std::string& path) {
    std::lock_guard<std::mutex> lock(mu_);
    persist_path_ = path;
    std::ifstream f(path);
    if (!f.good()) {
        // No prior state — keep the fresh UUID from the ctor + index=1, and
        // write the initial file so the next launch can resume.
        save_locked();
        return;
    }
    std::stringstream buf; buf << f.rdbuf();
    std::string blob = buf.str();
    if (blob.empty()) { save_locked(); return; }

    std::string saved_id     = read_str_field(blob, "session_id");
    std::string saved_prev   = read_str_field(blob, "previous_session_id");
    std::string saved_tid    = read_str_field(blob, "tracking_id");
    std::string saved_prev_tid = read_str_field(blob, "previous_tracking_id");
    int64_t saved_idx        = read_int_field(blob, "session_index");
    int64_t saved_started    = read_int_field(blob, "started_at_ms");
    int64_t saved_last_act   = read_int_field(blob, "last_activity_ms");

    if (saved_id.empty() || saved_idx <= 0) {
        // Corrupt or partial file — start fresh but keep index=1.
        save_locked();
        return;
    }

    int64_t now = current_time_ms();
    // Resume the persisted session iff it was active within the timeout
    // window. Otherwise treat the gap as a fresh launch and bump the index.
    if (now - saved_last_act <= timeout_ms_) {
        session_id_       = saved_id;
        // Resumed session — reuse persisted tracking_id (1:1 with session_id).
        // Fall back to the fresh ctor uuid for legacy state files that didn't
        // persist a tracking_id yet.
        if (!saved_tid.empty()) tracking_id_ = saved_tid;
        started_at_ms_    = saved_started ? saved_started : now;
        last_activity_ms_ = saved_last_act;
        session_index_    = saved_idx;
        // No previous_id for a resumed session — we didn't actually rotate.
        prev_id_.clear();
        prev_tracking_id_.clear();
    } else {
        // Gap exceeded timeout → roll forward. The newly generated session_id_
        // + tracking_id_ in the ctor stay; record the prior pair as previous +
        // bump index.
        prev_id_         = saved_id;
        prev_tracking_id_ = saved_tid;
        prev_started_ms_ = saved_started;
        prev_ended_ms_   = saved_last_act;
        prev_reason_     = SessionEndReason::timeout;
        pending_boundary_ = true;
        session_index_   = saved_idx + 1;
    }
    save_locked();
}

void SessionManager::save_locked() {
    if (persist_path_.empty()) return;
    std::ostringstream out;
    out << "{\"session_id\":\""          << session_id_           << "\","
        << "\"tracking_id\":\""          << tracking_id_          << "\","
        << "\"session_index\":"          << session_index_        << ","
        << "\"started_at_ms\":"          << started_at_ms_        << ","
        << "\"last_activity_ms\":"       << last_activity_ms_     << ","
        << "\"previous_session_id\":\""  << prev_id_              << "\","
        << "\"previous_tracking_id\":\"" << prev_tracking_id_     << "\"}";
    // Write atomically: dump to .tmp then rename. Survives a kill mid-write.
    std::string tmp = persist_path_ + ".tmp";
    {
        std::ofstream f(tmp, std::ios::trunc);
        if (!f.good()) return;
        f << out.str();
    }
    std::rename(tmp.c_str(), persist_path_.c_str());
}

void SessionManager::rotate_locked(SessionEndReason reason) {
    int64_t now = current_time_ms();
    // Record the session being closed so the next resolve() can emit a clean
    // session_end/start pair. If a boundary is already pending (rotated twice
    // before anyone resolved), keep the earliest prev_id but update the end —
    // we only emit one boundary, attributing it to the latest reason.
    if (!pending_boundary_) {
        prev_id_         = session_id_;
        prev_tracking_id_ = tracking_id_;
        prev_started_ms_ = started_at_ms_;
    }
    prev_ended_ms_    = now;
    prev_reason_      = reason;
    pending_boundary_ = true;

    session_id_       = generate_uuid();
    tracking_id_      = generate_uuid();
    started_at_ms_    = now;
    last_activity_ms_ = now;
    session_index_   += 1;
    first_event_id_.clear();
    save_locked();
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

int64_t SessionManager::current_session_index() {
    std::lock_guard<std::mutex> lock(mu_);
    return session_index_;
}

std::string SessionManager::previous_session_id() {
    std::lock_guard<std::mutex> lock(mu_);
    return prev_id_;
}

std::string SessionManager::current_tracking_id() {
    std::lock_guard<std::mutex> lock(mu_);
    int64_t now = current_time_ms();
    // Tracking id is 1:1 with session_id, so a timeout rotation must roll
    // both. Mirror the read-side rotation in current_session_id() to keep
    // hot-path callers consistent.
    if (now - last_activity_ms_ > timeout_ms_) {
        rotate_locked(SessionEndReason::timeout);
    }
    last_activity_ms_ = now;
    return tracking_id_;
}

std::string SessionManager::previous_tracking_id() {
    std::lock_guard<std::mutex> lock(mu_);
    return prev_tracking_id_;
}

SessionStamp SessionManager::stamp_for_event(const std::string& event_id) {
    std::lock_guard<std::mutex> lock(mu_);
    int64_t now = current_time_ms();
    if (now - last_activity_ms_ > timeout_ms_) {
        rotate_locked(SessionEndReason::timeout);
    }
    last_activity_ms_ = now;
    // Capture the first event id of this session the first time we see one.
    // Subsequent events in the same session echo this back as first_event_id.
    if (first_event_id_.empty() && !event_id.empty()) {
        first_event_id_ = event_id;
        save_locked();  // remember across launches
    }
    SessionStamp s;
    s.id                  = session_id_;
    s.tracking_id         = tracking_id_;
    s.index               = session_index_;
    s.previous_id         = prev_id_;
    s.previous_tracking_id = prev_tracking_id_;
    s.first_event_id      = first_event_id_;
    return s;
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
    r.tracking_id   = tracking_id_;
    r.started_at_ms = started_at_ms_;
    r.index         = session_index_;
    r.rotated       = pending_boundary_;
    if (pending_boundary_) {
        r.prev_id          = prev_id_;
        r.prev_tracking_id = prev_tracking_id_;
        r.prev_started_ms  = prev_started_ms_;
        r.prev_ended_ms    = prev_ended_ms_;
        r.prev_reason      = prev_reason_;
        // Consume the pending boundary — it is now the caller's job to emit it.
        pending_boundary_ = false;
        prev_reason_      = SessionEndReason::none;
    }
    return r;
}

void SessionManager::mark_activity() {
    std::lock_guard<std::mutex> lock(mu_);
    int64_t now = current_time_ms();
    // Throttle persistence: only re-save last_activity_ms every ~10s so a
    // chatty SDK call site doesn't hammer the disk. Worst-case a crash forgets
    // the most recent ≤10s of activity — well below the 30-min timeout, so
    // resume-on-launch logic still works as expected.
    bool need_save = (now - last_activity_ms_) > 10 * 1000;
    last_activity_ms_ = now;
    if (need_save) save_locked();
}

void SessionManager::set_timeout_ms(int64_t ms) {
    std::lock_guard<std::mutex> lock(mu_);
    timeout_ms_ = ms;
}

} // namespace unitrack
