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
    queue_.trim(config_.max_queue_size, config_.max_age_days, config_.max_retries);

    // Install signal-based crash handler.
    // Crash files live in the same directory as the queue DB.
    std::string dir = config_.db_path;
    auto slash = dir.find_last_of('/');
    dir = (slash == std::string::npos) ? "." : dir.substr(0, slash);
    CrashHandler::install(dir);

    // Pick up any crash captured on the previous launch. A crash recovered at
    // startup is, by definition, the crash that ended the *previous* session —
    // we can't time it against this init, so mark it not-on-launch (the SDK was
    // already up long enough last time to capture and persist it).
    std::string pending = CrashHandler::flush_pending_crash(dir);
    if (!pending.empty()) {
        track("crash", inject_crash_on_launch(pending, false));
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
    e.session_id   = session_.current_session_id();

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
    {
        std::lock_guard<std::mutex> lock(state_mu_);
        if (current_screen_ == screen_name) return;
        current_screen_ = screen_name;
    }
    std::string props = "{\"screen\":\"" + screen_name + "\"}";
    track("screen_view", props);
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
    session_.rotate();
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
    track("tap", o.str());
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

void Tracker::log_foreground() { track("app_foreground", "{}"); }
void Tracker::log_background() {
    track("app_background", "{}");
    flush_now();
}
void Tracker::log_app_start(long cold_start_ms) {
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
    } else {
        // Failed: keep the events, but back off exponentially so a downed
        // server isn't retried every flush interval.
        queue_.mark_retry(ids, config_.retry_base_ms, config_.retry_max_ms);
        UT_LOGW("Tracker", "flush failed; backing off before retry");
    }
    queue_.trim(config_.max_queue_size, config_.max_age_days, config_.max_retries);
}

} // namespace unitrack
