#include "tracker.h"
#include "crash_handler.h"
#include "logger.h"
#include "util.h"

#include <chrono>
#include <random>
#include <sstream>
#include <utility>

namespace unitrack {

static const char* platform_str(ut_platform p) {
    switch (p) {
        case UT_PLATFORM_IOS:          return "ios";
        case UT_PLATFORM_ANDROID:      return "android";
        case UT_PLATFORM_REACT_NATIVE: return "react-native";
        case UT_PLATFORM_FLUTTER:      return "flutter";
    }
    return "unknown";
}

Tracker::Tracker(Config cfg, ut_platform platform)
    : config_(std::move(cfg)),
      platform_(platform),
      queue_(config_.db_path),
      transport_(config_.endpoint, config_.api_key, config_.http_timeout_ms),
      session_()
{
    enabled_.store(config_.enabled);
    init_time_ms_ = current_time_ms();
    session_.set_timeout_ms(config_.session_timeout_ms);
    queue_.trim(config_.max_queue_size, config_.max_age_days, config_.max_retries);

    // Install signal-based crash handler.
    // Crash files live in the same directory as the queue DB.
    std::string dir = config_.db_path;
    auto slash = dir.find_last_of('/');
    dir = (slash == std::string::npos) ? "." : dir.substr(0, slash);
    CrashHandler::install(dir);

    // Restore session state from disk so session_id + session_index survive
    // across launches (Snowplow client_session parity). Must come AFTER the
    // session timeout is set above and BEFORE the first build_event call.
    session_.load_from(dir + "/session.json");

    // Pick up any crash captured on the previous launch. A crash recovered at
    // startup is, by definition, the crash that ended the *previous* session —
    // we can't time it against this init, so mark it not-on-launch (the SDK was
    // already up long enough last time to capture and persist it).
    std::string pending = CrashHandler::flush_pending_crash(dir);
    if (!pending.empty()) {
        std::string injected = inject_crash_on_launch(pending, false);
        track("crash", injected);
        // Stash for the binding to pop after providers initialize, so
        // Snowplow / Firebase / etc. see the recovered crash through
        // their own track() paths (the C++ track() above only reaches
        // the offline queue / portal HTTP, not platform providers).
        {
            std::lock_guard<std::mutex> lock(state_mu_);
            recovered_crash_json_ = injected;
        }
        // Crashes are too important to wait on the batch_size threshold —
        // a user who immediately kills the recovered app would lose the
        // event. Ask the worker to flush ASAP on its first tick.
        {
            std::lock_guard<std::mutex> lock(worker_mu_);
            flush_requested_ = true;
        }
    }

    worker_ = std::thread(&Tracker::worker_loop, this);
    UT_LOGI("Tracker", "initialized on platform " + std::string(platform_str(platform_)));
}

Tracker::~Tracker() {
    running_.store(false);
    {
        std::lock_guard<std::mutex> lock(worker_mu_);
        flush_requested_ = true;
    }
    worker_cv_.notify_all();
    if (worker_.joinable()) worker_.join();
    do_flush(); // best-effort final flush
}

bool Tracker::should_sample() {
    if (config_.sampling_rate >= 1.0) return true;
    if (config_.sampling_rate <= 0.0) return false;
    static thread_local std::mt19937 gen{std::random_device{}()};
    std::uniform_real_distribution<double> dist(0.0, 1.0);
    return dist(gen) < config_.sampling_rate;
}

Event Tracker::build_event(const std::string& name, const std::string& props_json) {
    Event e;
    e.event_id     = generate_uuid();
    e.event_name   = name;
    e.timestamp_ms = current_time_ms();
    // Stamp the full client_session bag onto every event so downstream can
    // aggregate by session_index / dedupe via first_event_id, matching the
    // shape Snowplow's tracker auto-attaches as a context entity.
    SessionStamp ss = session_.stamp_for_event(e.event_id);
    e.session_id           = ss.id;
    e.session_index        = ss.index;
    e.previous_session_id  = ss.previous_id;
    e.first_event_id       = ss.first_event_id;

    std::lock_guard<std::mutex> lock(state_mu_);
    e.user_id          = user_id_;
    e.screen           = current_screen_;
    e.properties_json  = props_json.empty() ? "{}" : props_json;
    e.device_json      = device_json_;
    return e;
}

void Tracker::enqueue(Event&& e) {
    if (!enabled_.load())                    return;
    if (e.event_name != "crash" && !should_sample()) return; // never sample out crashes

    if (!queue_.enqueue(e)) {
        UT_LOGW("Tracker", "enqueue failed for event " + e.event_name);
        return;
    }

    if (queue_.count() >= config_.batch_size) {
        std::lock_guard<std::mutex> lock(worker_mu_);
        flush_requested_ = true;
        worker_cv_.notify_one();
    }
}

void Tracker::track(const std::string& event_name, const std::string& props_json) {
    enqueue(build_event(event_name, props_json));
}

void Tracker::set_screen(const std::string& screen_name) {
    std::string previous;
    long long dwell_ms = 0;
    long long now = current_time_ms();
    {
        std::lock_guard<std::mutex> lock(state_mu_);
        if (current_screen_ == screen_name) {
            // Same name twice in a row = no boundary events. Log so a missing
            // screen_start/screen_end can be diagnosed without bisecting the
            // C++ side.
            UT_LOGI("Tracker", "set_screen(" + screen_name + ") deduped — same as current");
            return;
        }
        previous = current_screen_;
        if (!previous.empty() && screen_entered_at_ms_ > 0)
            dwell_ms = now - screen_entered_at_ms_;
        current_screen_ = screen_name;
        screen_entered_at_ms_ = now;
    }
    // What the core is ABOUT to fire — confirms screen_lifecycle flag + which
    // event names will be used (these come from portal sdk_config.screen_*).
    UT_LOGI("Tracker", "set_screen prev=\"" + previous + "\" new=\"" + screen_name +
            "\" lifecycle=" + (config_.screen_lifecycle ? "ON" : "off") +
            " start_event=\"" + config_.screen_start_event +
            "\" end_event=\""  + config_.screen_end_event + "\"");

    // screen_end for the screen we're leaving (with how long we stayed on it),
    // then screen_view (back-compat), then screen_start for the new screen.
    // Event names for start/end are configurable so teams can map them onto
    // their own taxonomy. The whole pair is gated by config_.screen_lifecycle.
    //
    // Payload contract matches the team Snowplow schema (vn.fpt.ftel.snowplow
    // /screen_view/jsonschema/1-0-0):
    //   end  → screen, screen_name (duplicate for schema field name),
    //          foreground_sec (= dwell_ms / 1000, rounded), dwell_ms (legacy),
    //          is_exit_screen (false here — session-level exit detection lives
    //          in the binding layer that owns lifecycle signals)
    //   view → screen, screen_name
    //   start→ screen, screen_name, from (legacy), from_screen, previous_screen_name
    // The duplicates keep older portal consumers reading the legacy field names
    // alive while the team Snowplow side reads the schema-aligned ones.
    if (config_.screen_lifecycle && !previous.empty()) {
        long long foreground_sec = (dwell_ms + 500) / 1000;  // round to nearest second
        track(config_.screen_end_event,
              "{\"screen\":\"" + previous +
              "\",\"screen_name\":\"" + previous +
              "\",\"foreground_sec\":" + std::to_string(foreground_sec) +
              ",\"dwell_ms\":" + std::to_string(dwell_ms) +
              ",\"is_exit_screen\":false}");
    }
    track("screen_view",
          "{\"screen\":\"" + screen_name +
          "\",\"screen_name\":\"" + screen_name + "\"}");
    if (config_.screen_lifecycle) {
        std::string start_payload = "{\"screen\":\"" + screen_name +
                                    "\",\"screen_name\":\"" + screen_name + "\"";
        if (!previous.empty()) {
            start_payload += ",\"from\":\"" + previous + "\"";
            start_payload += ",\"from_screen\":\"" + previous + "\"";
            start_payload += ",\"previous_screen_name\":\"" + previous + "\"";
        }
        start_payload += "}";
        track(config_.screen_start_event, start_payload);
    }
}

void Tracker::identify(const std::string& user_id, const std::string& traits_json) {
    {
        std::lock_guard<std::mutex> lock(state_mu_);
        user_id_          = user_id;
        user_traits_json_ = traits_json.empty() ? "{}" : traits_json;
    }
    track("identify", traits_json);
}

void Tracker::reset() {
    {
        std::lock_guard<std::mutex> lock(state_mu_);
        user_id_.clear();
        user_traits_json_ = "{}";
    }
    session_.rotate(SessionEndReason::manual_reset);
    // Surface session_end(manual_reset) + session_start for the new session.
    emit_session_boundary(SessionEndReason::manual_reset);
}

void Tracker::log_tap(const std::string& element_key,
                      const std::string& screen,
                      const std::string& extra_json) {
    std::ostringstream o;
    o << "{\"element_key\":\"" << element_key << "\","
      << "\"screen\":\""       << screen       << "\"";
    if (!extra_json.empty() && extra_json != "{}") {
        // assume extra_json is a valid JSON object like {"a":1}
        // merge by stripping outer braces
        o << "," << extra_json.substr(1, extra_json.size() - 2);
    }
    o << "}";
    // Convention name "click" so the Snowplow provider maps via portal
    // `event_names.click` (default → `event_click`). Matches the swizzlers
    // on iOS / Android / Flutter / RN — keeps the wire shape uniform.
    track("click", o.str());
}

void Tracker::log_network(const std::string& url, const std::string& method,
                          int status, long duration_ms,
                          long req_bytes, long resp_bytes,
                          const std::string& error) {
    std::ostringstream o;
    o << "{\"url\":\""    << url    << "\","
      << "\"method\":\""  << method << "\","
      << "\"status\":"    << status << ","
      << "\"duration_ms\":" << duration_ms << ","
      << "\"req_bytes\":"  << req_bytes  << ","
      << "\"resp_bytes\":" << resp_bytes;
    if (!error.empty()) o << ",\"error\":\"" << error << "\"";
    o << "}";
    track("network_request", o.str());
}

void Tracker::log_json_error(const std::string& target_type,
                             const std::string& error_msg,
                             const std::string& stack,
                             const std::string& data_preview) {
    std::ostringstream o;
    o << "{\"type\":\""       << target_type  << "\","
      << "\"error\":\""       << error_msg    << "\","
      << "\"stack\":\""       << stack        << "\","
      << "\"data_preview\":\"" << data_preview << "\"}";
    track("json_parse_error", o.str());
}

void Tracker::log_memory_warning(long used, long limit, const std::string& screen) {
    std::ostringstream o;
    o << "{\"memory_used\":"  << used  << ","
      << "\"memory_limit\":"  << limit << ","
      << "\"screen\":\""      << screen << "\"}";
    track("memory_warning", o.str());
}

// Merge a "crash_on_launch" boolean into a crash props JSON object, unless the
// caller already supplied one (e.g. the Flutter binding computes its own).
std::string Tracker::inject_crash_on_launch(const std::string& crash_json, bool on_launch) {
    // If the field is already present, leave the payload untouched.
    if (crash_json.find("\"crash_on_launch\"") != std::string::npos) return crash_json;
    const std::string field = std::string("\"crash_on_launch\":") + (on_launch ? "true" : "false");
    // Empty / non-object payload → wrap it.
    std::string s = crash_json;
    auto open = s.find('{');
    auto close = s.find_last_of('}');
    if (open == std::string::npos || close == std::string::npos || close <= open) {
        return "{" + field + "}";
    }
    // Insert the field right after the opening brace.
    bool emptyObj = s.find_first_not_of(" \t\r\n", open + 1) == close;
    std::string sep = emptyObj ? "" : ",";
    s.insert(open + 1, field + sep);
    return s;
}

void Tracker::log_crash(const std::string& crash_json) {
    // A crash within the launch window is flagged so the portal can surface
    // "crashed right after opening the app".
    bool on_launch = (current_time_ms() - init_time_ms_) <= kLaunchCrashWindowMs;
    track("crash", inject_crash_on_launch(crash_json, on_launch));
    // Crashes should hit disk immediately — flush synchronously.
    do_flush();
}

const char* Tracker::session_end_reason_str(SessionEndReason r) {
    switch (r) {
        case SessionEndReason::timeout:       return "timeout";
        case SessionEndReason::manual_reset:  return "manual_reset";
        case SessionEndReason::none:          return "none";
    }
    return "none";
}

// Resolve the session and, if it just rotated, emit a session_end for the
// closed session followed by a session_start for the new one. The session_end
// carries the *closed* session id + duration in its properties (its own
// envelope session_id is the new session, which the portal ignores for this
// event). session_start marks the new session opening.
void Tracker::emit_session_boundary(SessionEndReason on_rotate) {
    if (!config_.journey_capture) return;

    SessionResolution s = session_.resolve(on_rotate);
    if (s.rotated) {
        std::ostringstream end;
        end << "{\"session_id\":\"" << s.prev_id << "\","
            << "\"reason\":\""      << session_end_reason_str(s.prev_reason) << "\","
            << "\"duration_ms\":"   << (s.prev_ended_ms - s.prev_started_ms) << ","
            << "\"started_at\":"    << s.prev_started_ms << ","
            << "\"ended_at\":"      << s.prev_ended_ms << "}";
        track("session_end", end.str());
    }
    // Emit session_start the first time we see this session id (rotation, or the
    // process's very first session at app_start). We dedupe via started_session_.
    {
        std::lock_guard<std::mutex> lock(state_mu_);
        if (started_session_ == s.id) return;
        started_session_ = s.id;
    }
    std::ostringstream start;
    start << "{\"session_id\":\"" << s.id << "\","
          << "\"started_at\":"    << s.started_at_ms << "}";
    track("session_start", start.str());
}

void Tracker::log_foreground() {
    // A long background may have elapsed the session timeout — surface the
    // boundary before recording the foreground event.
    emit_session_boundary(SessionEndReason::timeout);
    track("app_foreground", "{}");
}
void Tracker::log_background() {
    track("app_background", "{}");
    flush_now();
}
void Tracker::log_app_start(long cold_start_ms) {
    // Open the process's first session boundary (session_start) on launch.
    emit_session_boundary(SessionEndReason::timeout);
    std::ostringstream o;
    o << "{\"cold_start_ms\":" << cold_start_ms << "}";
    track("app_start", o.str());
}

void Tracker::flush_now() {
    std::lock_guard<std::mutex> lock(worker_mu_);
    flush_requested_ = true;
    worker_cv_.notify_one();
}

void Tracker::worker_loop() {
    while (running_.load()) {
        std::unique_lock<std::mutex> lock(worker_mu_);
        worker_cv_.wait_for(lock,
            std::chrono::milliseconds(config_.flush_interval_ms),
            [this]{ return flush_requested_ || !running_.load(); });
        flush_requested_ = false;
        lock.unlock();

        if (!running_.load()) break;
        do_flush();
    }
}

void Tracker::do_flush() {
    auto batch = queue_.peek(config_.batch_size);
    if (batch.empty()) return;

    // Each row's `payload` column holds the full pre-serialized event JSON
    // (set when enqueue() called Event::to_json()). OfflineQueue::peek loads
    // it into DequeuedEvent.event.properties_json for convenience — we just
    // concat into a JSON array here.
    std::ostringstream o;
    o << '[';
    bool first = true;
    std::vector<int64_t> ids;
    ids.reserve(batch.size());
    for (auto& d : batch) {
        if (!first) o << ',';
        o << d.event.properties_json;
        first = false;
        ids.push_back(d.row_id);
    }
    o << ']';

    if (transport_.send(o.str())) {
        queue_.remove(ids);
        UT_LOGD("Tracker", "flushed " + std::to_string(ids.size()) + " events");

        // Notify the binding so apps can show a "Flushed: 3 ev_click, ..."
        // toast on real-device offline tests. Tally event_name from the batch
        // itself (already have it in DequeuedEvent.event.event_name — no need
        // to re-parse payload). Snapshot the callback under the lock so a
        // concurrent set_flush_callback can't tear the function/userdata pair.
        FlushCallback cb;  void* cb_ud;
        { std::lock_guard<std::mutex> lk(state_mu_); cb = flush_cb_; cb_ud = flush_cb_data_; }
        if (cb) {
            std::vector<std::pair<std::string, int>> counts;
            counts.reserve(8);
            for (auto& d : batch) {
                bool found = false;
                for (auto& p : counts) {
                    if (p.first == d.event.event_name) { p.second += 1; found = true; break; }
                }
                if (!found) counts.emplace_back(d.event.event_name, 1);
            }
            std::ostringstream cj;
            cj << '{';
            bool cfirst = true;
            for (auto& p : counts) {
                if (!cfirst) cj << ',';
                cfirst = false;
                cj << '"' << p.first << "\":" << p.second;
            }
            cj << '}';
            cb(cj.str().c_str(), cb_ud);
        }
    } else {
        // Failed: keep the events, but back off exponentially so a downed
        // server isn't retried every flush interval.
        queue_.mark_retry(ids, config_.retry_base_ms, config_.retry_max_ms);
        UT_LOGW("Tracker", "flush failed; backing off before retry");
    }
    queue_.trim(config_.max_queue_size, config_.max_age_days, config_.max_retries);
}

std::string Tracker::pending_event_counts_json() {
    auto pairs = queue_.counts_by_event_name();
    if (pairs.empty()) return "{}";
    std::ostringstream o;
    o << '{';
    bool first = true;
    for (auto& p : pairs) {
        if (!first) o << ',';
        first = false;
        // Event names are SDK-internal identifiers (ev_click, ev_screen_view…)
        // — ASCII, no escaping needed. Wrap defensively anyway with " quotes.
        o << '"' << p.first << "\":" << p.second;
    }
    o << '}';
    return o.str();
}

} // namespace unitrack
