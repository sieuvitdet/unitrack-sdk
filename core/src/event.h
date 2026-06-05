#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>

namespace unitrack {

struct Event {
    std::string event_id;       // UUID
    std::string event_name;     // e.g. "screen_view", "tap", "network_request"
    int64_t     timestamp_ms;   // Unix epoch ms
    std::string session_id;
    // Snowplow client_session-style session metadata. Stamped on every event
    // so downstream can answer "session #N of user", "is this the first event
    // of the session", "what was the previous session". Mirrors the shape of
    // iglu:com.snowplowanalytics.snowplow/client_session/jsonschema/1-0-2 so a
    // single warehouse query can union both sources.
    int64_t     session_index = 0;     // 1-based, lifetime counter (persists across launches)
    std::string previous_session_id;   // empty for the very first session
    std::string first_event_id;        // event_id of the first event in this session
    std::string user_id;        // empty if anonymous
    std::string screen;
    std::string properties_json; // raw JSON object string, may be "{}"
    std::string device_json;     // device/app metadata JSON object, may be empty

    // Serialized to JSON for transport.
    std::string to_json() const;
};

} // namespace unitrack
