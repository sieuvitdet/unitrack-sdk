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
    std::string user_id;        // empty if anonymous
    std::string screen;
    std::string properties_json; // raw JSON object string, may be "{}"
    std::string device_json;     // device/app metadata JSON object, may be empty

    // Serialized to JSON for transport.
    std::string to_json() const;
};

} // namespace unitrack
