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
    std::string tracking_id;   // current tracking id (1:1 with session id)
    int64_t     started_at_ms; // when the current session started
    int64_t     index;         // 1-based session counter (lifetime, persisted)
    bool        rotated;       // true if this call started a new session
    std::string      prev_id;        // closed session id (valid when rotated)
    std::string      prev_tracking_id; // closed tracking id (valid when rotated)
    int64_t          prev_started_ms; // closed session start (valid when rotated)
    int64_t          prev_ended_ms;   // closed session end   (valid when rotated)
    SessionEndReason prev_reason;     // why the previous session closed
};

// Bag of fields stamped on every event so downstream can answer
// "session #N", "is this the first event of the session", "previous session?"
// Mirrors Snowplow iglu:.../client_session/jsonschema/1-0-2 (subset).
struct SessionStamp {
    std::string id;
    std::string tracking_id;       // 1:1 with id — minted on every rotation
    int64_t     index = 0;
    std::string previous_id;
    std::string previous_tracking_id;
    std::string first_event_id;
};

class SessionManager {
public:
    SessionManager();

    // Load persisted state from `path` (a file inside the storage dir). If the
    // file exists and the last activity is within the timeout, the existing
    // session is resumed; otherwise a new one is opened and `index` increments.
    // Safe to call once at Tracker init — no-op for a never-launched app.
    void load_from(const std::string& path);

    // Returns the current session id, starting a new one if the timeout
    // elapsed. Does NOT report rotation — use resolve() when you need to emit
    // session boundaries. Kept for hot-path callers that only need the id.
    std::string current_session_id();

    // Read-only views of the persisted session state. Cheap snapshot under
    // the same mutex as current_session_id(). Bindings expose these so apps
    // can stamp session_index / previous_session_id onto custom events
    // without holding a SessionStamp object.
    int64_t     current_session_index();
    std::string previous_session_id();

    // Tracking id: a UUID minted alongside session_id on every rotation. It is
    // 1:1 with session_id but lives only in our domain — Portal stores the
    // user → session_id → tracking_id map and stamps the tracking_id on
    // outgoing Snowplow events so operators can pivot from a Portal lookup to
    // the full event timeline in Snowplow.
    std::string current_tracking_id();
    std::string previous_tracking_id();

    // Stamp for the current event: id, index, previous_id, first_event_id.
    // Pass the event_id of the event being built — if this is the first
    // event in the session it is recorded so subsequent events can quote it.
    SessionStamp stamp_for_event(const std::string& event_id);

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
    std::string    tracking_id_;
    int64_t        started_at_ms_    = 0;
    int64_t        last_activity_ms_ = 0;
    int64_t        timeout_ms_       = 30 * 60 * 1000;  // 30 min default

    // Persisted across launches via load_from + save_locked. session_index_
    // increments on every rotation (first install = 1). first_event_id_ is
    // captured by stamp_for_event() so we can echo it on every later event.
    int64_t     session_index_   = 1;
    std::string first_event_id_;
    std::string persist_path_;     // empty until load_from() is called

    // Pending boundary, set when a rotation occurs, consumed by the next
    // resolve(). Lets a timeout-driven rotation (detected mid hot-path) still
    // surface a clean session_end/start pair on the next lifecycle resolve.
    bool             pending_boundary_ = false;
    std::string      prev_id_;
    std::string      prev_tracking_id_;
    int64_t          prev_started_ms_ = 0;
    int64_t          prev_ended_ms_   = 0;
    SessionEndReason prev_reason_     = SessionEndReason::none;

    // Rotate, recording the closed session into the pending-boundary fields.
    void rotate_locked(SessionEndReason reason);
    // Write current state to persist_path_ (no-op if path is empty). Called
    // after every rotation + on activity beyond a small in-memory threshold so
    // the on-disk last_activity_ms reflects reality within ~10s.
    void save_locked();
};

} // namespace unitrack
