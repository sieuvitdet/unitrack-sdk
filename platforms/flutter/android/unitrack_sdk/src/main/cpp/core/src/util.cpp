#include "util.h"
#include <chrono>
#include <random>
#include <cstdio>

namespace unitrack {

std::string generate_uuid() {
    static thread_local std::mt19937_64 gen{std::random_device{}()};
    std::uniform_int_distribution<uint64_t> dist;
    uint64_t a = dist(gen);
    uint64_t b = dist(gen);

    // Set version (4) and variant (10xx) bits per RFC 4122.
    a = (a & 0xFFFFFFFFFFFF0FFFULL) | 0x0000000000004000ULL;
    b = (b & 0x3FFFFFFFFFFFFFFFULL) | 0x8000000000000000ULL;

    char buf[37];
    snprintf(buf, sizeof(buf),
             "%08x-%04x-%04x-%04x-%012llx",
             (unsigned)((a >> 32) & 0xFFFFFFFFu),
             (unsigned)((a >> 16) & 0xFFFFu),
             (unsigned)(a & 0xFFFFu),
             (unsigned)((b >> 48) & 0xFFFFu),
             (unsigned long long)(b & 0xFFFFFFFFFFFFULL));
    return std::string(buf);
}

int64_t current_time_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(
        system_clock::now().time_since_epoch()).count();
}

} // namespace unitrack
