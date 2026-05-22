#pragma once

#include <cstdint>
#include <string>

namespace unitrack {

// Generates a RFC4122 v4-like UUID using std::random_device.
// Format: xxxxxxxx-xxxx-4xxx-Nxxx-xxxxxxxxxxxx
std::string generate_uuid();

// Current time in milliseconds since Unix epoch.
int64_t current_time_ms();

} // namespace unitrack
