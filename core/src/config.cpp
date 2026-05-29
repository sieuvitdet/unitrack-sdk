#include "config.h"
#include <cstdlib>
#include <cctype>

namespace unitrack {

// Tiny string-based JSON value extractor — not a full parser, just enough
// to read top-level key/value pairs from the config object.
// We avoid pulling in a JSON dependency for the config path.

static std::string find_string(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    auto p = json.find(needle);
    if (p == std::string::npos) return "";
    p = json.find(':', p);
    if (p == std::string::npos) return "";
    p = json.find('"', p);
    if (p == std::string::npos) return "";
    // Walk to the closing quote, honoring backslash escapes, and decode the
    // standard JSON escapes as we go. (Without this, a value like an absolute
    // path serialized as "\/data\/..." by some JSON encoders would keep its
    // backslashes and break, e.g. sqlite3_open on Android.)
    std::string out;
    for (size_t i = p + 1; i < json.size(); ++i) {
        char ch = json[i];
        if (ch == '\\' && i + 1 < json.size()) {
            char nx = json[++i];
            switch (nx) {
                case 'n': out.push_back('\n'); break;
                case 't': out.push_back('\t'); break;
                case 'r': out.push_back('\r'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case '/': out.push_back('/');  break;
                case '"': out.push_back('"');  break;
                case '\\': out.push_back('\\'); break;
                case 'u': {
                    // Minimal \uXXXX handling: keep ASCII, drop the rest.
                    if (i + 4 < json.size()) {
                        int code = std::strtol(json.substr(i + 1, 4).c_str(), nullptr, 16);
                        if (code > 0 && code < 128) out.push_back(static_cast<char>(code));
                        i += 4;
                    }
                    break;
                }
                default: out.push_back(nx); break;
            }
        } else if (ch == '"') {
            return out;          // unescaped closing quote
        } else {
            out.push_back(ch);
        }
    }
    return out;
}

static bool find_number(const std::string& json, const std::string& key, double& out) {
    std::string needle = "\"" + key + "\"";
    auto p = json.find(needle);
    if (p == std::string::npos) return false;
    p = json.find(':', p);
    if (p == std::string::npos) return false;
    ++p;
    while (p < json.size() && std::isspace(static_cast<unsigned char>(json[p]))) ++p;
    if (p >= json.size()) return false;
    char* endp = nullptr;
    out = std::strtod(json.c_str() + p, &endp);
    return endp != json.c_str() + p;
}

static bool find_bool(const std::string& json, const std::string& key, bool& out) {
    std::string needle = "\"" + key + "\"";
    auto p = json.find(needle);
    if (p == std::string::npos) return false;
    p = json.find(':', p);
    if (p == std::string::npos) return false;
    if (json.find("true",  p) == p + 1 + json.find_first_not_of(" \t", p + 1) - p) {}
    // simpler:
    while (p < json.size() && (json[p] == ':' || std::isspace(static_cast<unsigned char>(json[p])))) ++p;
    if (json.compare(p, 4, "true") == 0)  { out = true;  return true; }
    if (json.compare(p, 5, "false") == 0) { out = false; return true; }
    return false;
}

Config Config::from_json(const std::string& api_key, const std::string& json) {
    Config c;
    c.api_key = api_key;
    if (json.empty()) return c;

    std::string s = find_string(json, "endpoint");
    if (!s.empty()) c.endpoint = s;

    s = find_string(json, "db_path");
    if (!s.empty()) c.db_path = s;

    double n = 0;
    if (find_number(json, "batch_size", n))        c.batch_size        = (int)n;
    if (find_number(json, "flush_interval_ms", n)) c.flush_interval_ms = (int)n;
    if (find_number(json, "max_queue_size", n))    c.max_queue_size    = (int)n;
    if (find_number(json, "max_age_days", n))      c.max_age_days      = (int)n;
    if (find_number(json, "sampling_rate", n))     c.sampling_rate     = n;
    if (find_number(json, "http_timeout_ms", n))   c.http_timeout_ms   = (int)n;
    if (find_number(json, "retry_base_ms", n))     c.retry_base_ms     = (int)n;
    if (find_number(json, "retry_max_ms", n))      c.retry_max_ms      = (int)n;
    if (find_number(json, "max_retries", n))       c.max_retries       = (int)n;
    if (find_number(json, "session_timeout_ms", n)) c.session_timeout_ms = (int)n;

    bool b = true;
    if (find_bool(json, "enabled", b))         c.enabled         = b;
    if (find_bool(json, "auto_capture", b))    c.auto_capture    = b;
    if (find_bool(json, "journey_capture", b)) c.journey_capture = b;
    if (find_bool(json, "screen_lifecycle", b)) c.screen_lifecycle = b;

    // Optional custom names for the screen lifecycle events (renameable taxonomy).
    s = find_string(json, "screen_start_event");
    if (!s.empty()) c.screen_start_event = s;
    s = find_string(json, "screen_end_event");
    if (!s.empty()) c.screen_end_event = s;

    return c;
}

} // namespace unitrack
