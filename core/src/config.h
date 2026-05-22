#pragma once

#include <string>

namespace unitrack {

struct Config {
    std::string endpoint        = "https://ingest.unitrack.io/v1/events";
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

    // Parses a JSON config string. Unknown / missing keys keep defaults.
    // Robust against malformed JSON — returns defaults on parse failure.
    static Config from_json(const std::string& api_key,
                            const std::string& json);
};

} // namespace unitrack
