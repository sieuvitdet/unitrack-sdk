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
    killed_recovered,    // app bị kill (user swipe khỏi switcher / Force Stop);
                         // phát hiện ở cold start kế tiếp qua clean_shutdown flag.
                         // Session_ended được fire NGAY khi app mở lại — không
                         // phải đợi 30 phút timeout. Khác `timeout` ở chỗ
                         // background gap < sessionTimeoutMs.
};

// Snapshot returned when resolving the current session. If `rotated` is true,
// a new session has just begun and `prev_*` describe the session that closed —
// the Tracker uses this to emit session_end(prev) + session_start(current).
struct SessionResolution {
    std::string id;            // current (possibly new) session id
    int64_t     started_at_ms; // when the current session started
    int64_t     index;         // 1-based session counter (lifetime, persisted)
    bool        rotated;       // true if this call started a new session
    std::string      prev_id;        // closed session id (valid when rotated)
    int64_t          prev_started_ms; // closed session start (valid when rotated)
    int64_t          prev_ended_ms;   // closed session end   (valid when rotated)
    SessionEndReason prev_reason;     // why the previous session closed
};

// Bag of fields stamped on every event so downstream can answer
// "session #N", "is this the first event of the session", "previous session?"
// Mirrors Snowplow iglu:.../client_session/jsonschema/1-0-2 (subset).
struct SessionStamp {
    std::string id;
    int64_t     index = 0;
    std::string previous_id;
    std::string first_event_id;
};

class SessionManager {
public:
    SessionManager();

    // Load persisted state from `path` (a file inside the storage dir). If the
    // file exists and the last activity is within the timeout, the existing
    // session is resumed; otherwise a new one is opened and `index` increments.
    // Safe to call once at Tracker init — no-op for a never-launched app.
    // `headless` = process khởi động không do user mở app (FCM wake, job).
    // Khi true, session đã persist được giữ nguyên và KHÔNG rotate, kể cả
    // clean_shutdown=0 — vì "app chết mà không qua background" là trạng thái
    // bình thường của một process headless, không phải dấu hiệu bị kill.
    void load_from(const std::string& path, bool headless = false);

    // Đánh dấu process này là headless. load_from() tự set, nhưng binding có
    // thể gọi trực tiếp khi biết trước (vd iOS đọc applicationState).
    void set_headless(bool v);

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

    // Stamp for the current event: id, index, previous_id, first_event_id.
    // Pass the event_id of the event being built — if this is the first
    // event in the session it is recorded so subsequent events can quote it.
    SessionStamp stamp_for_event(const std::string& event_id);

    // Resolve the current session and report whether it just rotated (and why).
    // Pass the reason to attribute to a rotation triggered by this call.
    SessionResolution resolve(SessionEndReason on_rotate = SessionEndReason::timeout);

    // Mark activity — extends the current session.
    void mark_activity();

    // Test-only: pretend `ms` of activity time has already elapsed, so a test
    // can cross the save throttle without sleeping. Not part of the SDK
    // surface — no binding calls this.
    void rewind_activity_for_test(int64_t ms);

    // Test-only: read the in-memory activity clock.
    int64_t last_activity_for_test();

    // Force start a new session (e.g. on app foreground after long bg, or
    // identify reset). The next resolve() reports the rotation with `reason`.
    void rotate(SessionEndReason reason = SessionEndReason::manual_reset);

    // Mark "clean shutdown": app vào background hợp lệ (didEnterBackground /
    // ProcessLifecycle ON_STOP). Ghi vào state file. Lần cold start sau,
    // load_from() đọc flag này — nếu vẫn `false` (app bị kill trước khi save
    // được), surfaces một pending boundary với reason killed_recovered để
    // Tracker fire session_ended cho session đã chết.
    void mark_clean_shutdown();

    void set_timeout_ms(int64_t ms);

    // Namespace salt for generated session ids (config `session_id_salt`).
    // Must be called BEFORE load_from() — the ctor has already minted an id by
    // then, so this re-tags it in place. Empty salt = untagged ids (default,
    // byte-identical to the pre-salt format). Changing the salt does NOT
    // invalidate a resumed session: a persisted id is replayed exactly as
    // stored, so ids stay stable across a config change mid-session.
    void set_salt(const std::string& salt);

    // Grace window for an unclean relaunch. Below this, a launch with
    // clean_shutdown=0 RESUMES the stored session instead of reporting a kill:
    // force-quit-then-reopen inside a few seconds is one period of use, and
    // iOS may also kill a suspended app before the state write lands, so a
    // missing flag alone is not proof of a kill. Deliberately small — a
    // genuine kill the user returns from later still rotates.
    static constexpr int64_t KILL_GRACE_MS = 10 * 1000;  // 10s

    // How often stamp_for_event()/resolve()/mark_activity() flush the advancing
    // last_activity_ms_ to disk. Bounds the error that load_from() sees on the
    // next launch, so it must stay well under KILL_GRACE_MS.
    static constexpr int64_t ACTIVITY_SAVE_INTERVAL_MS = 10 * 1000;  // 10s

private:
    std::mutex     mu_;
    std::string    salt_;
    std::string    session_id_;
    int64_t        started_at_ms_    = 0;
    int64_t        last_activity_ms_ = 0;
    // True cho cả vòng đời của một process headless (FCM wake, job, boot
    // receiver). Noti KHÔNG phải user hoạt động: một process không UI không
    // được đẩy last_activity_ms_ và không được rotate. Nếu nó đẩy, mỗi noti
    // reset lại đồng hồ timeout — đo 2026-08-21 trên Xiaomi: 60 noti giữ một
    // session sống 9.5 giờ trong khi phiên dùng thật chỉ 15 phút, và lần user
    // mở app sau đó không rotate vì đồng hồ vừa bị noti reset.
    bool           headless_process_ = false;
    int64_t        timeout_ms_       = 30 * 60 * 1000;  // 30 min default
    // True khi app vào background bình thường + save xong. Ghi vào state
    // file. Cold start tiếp theo đọc lại: false = app bị kill (didEnter-
    // Background không kịp / không chạy). Kết hợp với gap < timeout thì
    // SDK fire session_ended ngay (reason=killed_recovered) thay vì đợi
    // 30 phút timeout.
    bool           clean_shutdown_   = false;

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
