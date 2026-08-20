#pragma once

#include <string>

namespace unitrack {

struct Config {
    std::string endpoint        = "";
    std::string api_key;
    std::string db_path         = "unitrack_queue.db";
    int         batch_size      = 50;
    int         flush_interval_ms = 5000;
    int         max_queue_size  = 10000;
    int         max_age_days    = 7;
    double      sampling_rate   = 1.0;
    bool        enabled         = true;
    bool        auto_capture    = true;
    int         http_timeout_ms = 15000;

    // Session journey tracking. When journey_capture is on, the Tracker emits
    // explicit session_start / session_end boundary events so the portal can
    // reconstruct each session's flow. session_timeout_ms is the inactivity /
    // background window after which a session is considered closed.
    bool        journey_capture   = true;
    int         session_timeout_ms = 30 * 60 * 1000;  // 30 min

    // Optional namespace salt for session ids (config `session_id_salt`).
    // When set, ids are emitted as "<8-hex tag>-<uuid>" where the tag derives
    // from this salt — so two app flavours / tenants writing into one
    // warehouse table can never collide, and an id is traceable to the config
    // that minted it. The UUID keeps all 122 random bits regardless: the tag
    // is a prefix, never mixed into the entropy.
    //
    // Empty (default) → bare UUIDv4, byte-identical to the pre-salt format.
    // Do NOT derive this from device identity — a device-derived salt would
    // make ids deterministic per device, which is a collision AND a
    // fingerprint. Use a per-project constant.
    std::string session_id_salt;

    // Headless launch: process khởi động KHÔNG do user mở app (Android FCM
    // đánh thức để xử lý push, WorkManager job, boot receiver…). Session là
    // "phiên sử dụng của user", nên một process không có UI không được tạo
    // session mới — nếu không, mỗi push camera lại đẻ một session sống 3
    // giây, không screen, không user (đo được: session_index 1917 trên một
    // máy prod). Khi cờ này bật, load_from() giữ nguyên session đã persist
    // và không rotate; event vẫn stamp session_id cũ.
    //
    // iOS không set cờ này: noti không đánh thức process nên vấn đề không
    // tồn tại. Giữ mặc định false để hành vi cũ không đổi.
    bool        headless_launch   = false;

    // Screen lifecycle. When set_screen() switches screens, the Tracker emits a
    // screen_view (always, back-compat) plus — when screen_lifecycle is on — a
    // "screen_end" for the screen being left (carrying dwell_ms = time spent on
    // it) and a "screen_start" for the one being entered. The event NAMES are
    // configurable so a team can map them onto their own taxonomy without an
    // app rebuild (e.g. "page_enter" / "page_leave").
    bool        screen_lifecycle   = true;
    // Defaults are BUSINESS names, matching the binding layer. "screen_start"/
    // "screen_end" were schema-shaped placeholders that no data spec uses; a
    // host that omits these keys used to ship event names nobody consumes.
    std::string screen_start_event = "screen_viewed";
    std::string screen_end_event   = "screen_exited";

    // Exponential backoff for failed flushes. After a failed send, an event is
    // not retried until now + min(retry_base_ms * 2^(retry_count-1), retry_max_ms),
    // with jitter, so a downed server is not hammered every flush interval.
    int         retry_base_ms   = 5000;     // first retry delay
    int         retry_max_ms    = 300000;   // cap (5 minutes)
    int         max_retries     = 10;       // drop the event after this many failures

    // Parses a JSON config string. Unknown / missing keys keep defaults.
    // Robust against malformed JSON — returns defaults on parse failure.
    static Config from_json(const std::string& api_key,
                            const std::string& json);
};

} // namespace unitrack
