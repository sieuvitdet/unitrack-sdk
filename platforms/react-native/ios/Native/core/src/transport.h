#pragma once

#include "../include/unitrack/unitrack.h"
#include <string>

namespace unitrack {

class Transport {
public:
    Transport(std::string endpoint, std::string api_key, int timeout_ms);

    void set_callback(ut_http_send_fn fn, void* user_data);

    // Send batched JSON payload. Returns true on 2xx.
    // payload is a JSON array string: [{...},{...}]
    bool send(const std::string& payload);

private:
    std::string       endpoint_;
    std::string       api_key_;
    int               timeout_ms_;
    ut_http_send_fn   http_fn_   = nullptr;
    void*             user_data_ = nullptr;

    // Built-in HTTP via libcurl when no callback set.
    bool send_builtin(const std::string& payload);
};

} // namespace unitrack
