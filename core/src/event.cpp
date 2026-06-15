#include "event.h"
#include <sstream>

namespace unitrack {

// Minimal JSON string escaper — handles control chars, quotes, backslashes.
static void escape_json(std::ostringstream& out, const std::string& s) {
    out << '"';
    for (char c : s) {
        switch (c) {
            case '"':  out << "\\\""; break;
            case '\\': out << "\\\\"; break;
            case '\b': out << "\\b";  break;
            case '\f': out << "\\f";  break;
            case '\n': out << "\\n";  break;
            case '\r': out << "\\r";  break;
            case '\t': out << "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out << buf;
                } else {
                    out << c;
                }
        }
    }
    out << '"';
}

std::string Event::to_json() const {
    std::ostringstream o;
    o << '{';
    o << "\"event_id\":";   escape_json(o, event_id);    o << ',';
    o << "\"event_name\":"; escape_json(o, event_name);  o << ',';
    o << "\"timestamp\":"  << timestamp_ms              << ',';
    o << "\"session_id\":"; escape_json(o, session_id);  o << ',';
    // Snowplow client_session parity — emitted even when index=0 / prev=""
    // (downstream pipeline expects the keys to always exist).
    o << "\"session_index\":" << session_index << ',';
    if (!previous_session_id.empty()) {
        o << "\"previous_session_id\":"; escape_json(o, previous_session_id); o << ',';
    }
    if (!first_event_id.empty()) {
        o << "\"first_event_id\":"; escape_json(o, first_event_id); o << ',';
    }
    if (!tracking_id.empty()) {
        o << "\"tracking_id\":"; escape_json(o, tracking_id); o << ',';
    }
    if (!previous_tracking_id.empty()) {
        o << "\"previous_tracking_id\":"; escape_json(o, previous_tracking_id); o << ',';
    }
    if (!user_id.empty()) {
        o << "\"user_id\":"; escape_json(o, user_id);    o << ',';
    }
    o << "\"screen\":";     escape_json(o, screen);      o << ',';
    // device_json is set once at init (model, OS, app version, locale, …).
    if (!device_json.empty()) {
        o << "\"device\":" << device_json << ',';
    }
    // properties_json is already valid JSON object string
    o << "\"properties\":" << (properties_json.empty() ? "{}" : properties_json);
    o << '}';
    return o.str();
}

} // namespace unitrack
