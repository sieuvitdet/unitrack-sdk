#include "util.h"
#include <chrono>
#include <random>
#include <cstdio>
#include <cstring>

#if defined(_WIN32)
#  include <windows.h>
#  include <bcrypt.h>
#else
#  include <errno.h>
#  include <stdlib.h>
#  include <unistd.h>
#  if !defined(__APPLE__)
#    include <sys/syscall.h>
#  endif
#endif

namespace unitrack {

// Fill `out` with `len` cryptographically random bytes straight from the OS.
//
// WHY NOT std::random_device + mt19937_64 (what this used to do):
//   `static thread_local std::mt19937_64 gen{std::random_device{}()};`
// std::random_device::result_type is 32 bits on every platform we ship, so
// seeding a 64-bit Mersenne Twister from ONE call gave the generator only 2^32
// distinct starting states — not the 122 bits the UUID format implies. Every id
// that process ever emitted was a pure function of that single 32-bit seed, so
// two devices drawing the same seed produced byte-identical UUIDs from then on.
// Measured: first duplicate after ~61k cold starts (birthday bound on 2^32),
// and that is exactly how session 41ce987d reached two different handsets.
//
// The OS CSPRNG has no seed to collide: getrandom/arc4random/BCrypt draw from a
// kernel entropy pool that is per-device, continuously reseeded, and designed so
// outputs are unpredictable even to an attacker who knows prior outputs. There
// is no PRNG state in this path at all.
static bool os_random_bytes(unsigned char* out, size_t len) {
#if defined(_WIN32)
    return BCryptGenRandom(nullptr, out, (ULONG)len,
                           BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0;
#elif defined(__APPLE__)
    // iOS/macOS: arc4random_buf is the CSPRNG in libSystem — same entropy
    // source as SecRandomCopyBytes but with no framework to link, so every
    // consumer of this static lib keeps its existing link line. Cannot fail.
    arc4random_buf(out, len);
    return true;
#else
    // Android/Linux. getrandom(2) first — no file descriptor needed, so it
    // works even when the app has exhausted its fd limit or /dev is not
    // mounted. Present since Linux 3.17 / Android API 28 (and bionic routes
    // older API levels through to the same syscall).
    size_t got = 0;
    while (got < len) {
        long n = syscall(SYS_getrandom, out + got, len - got, 0);
        if (n > 0) { got += (size_t)n; continue; }
        if (n < 0 && errno == EINTR) continue;   // signal, retry
        break;                                    // ENOSYS / EAGAIN → fall back
    }
    if (got == len) return true;

    // Fallback for kernels without getrandom: read /dev/urandom directly.
    FILE* f = fopen("/dev/urandom", "rb");
    if (!f) return false;
    size_t rd = fread(out + got, 1, len - got, f);
    fclose(f);
    return (got + rd) == len;
#endif
}

uint64_t secure_random_u64() {
    uint64_t v = 0;
    unsigned char buf8[8];
    if (os_random_bytes(buf8, sizeof(buf8))) {
        std::memcpy(&v, buf8, sizeof(v));
        return v;
    }
    // Degraded path — see generate_uuid() for why random_device is drawn at
    // full width instead of once.
    std::random_device rd;
    for (int i = 0; i < 64; i += 32) v = (v << 32) | (uint64_t)rd();
    return v;
}

std::string generate_uuid() {
    uint64_t a = 0, b = 0;
    unsigned char buf16[16];
    if (os_random_bytes(buf16, sizeof(buf16))) {
        std::memcpy(&a, buf16,     sizeof(a));
        std::memcpy(&b, buf16 + 8, sizeof(b));
    } else {
        // Last-resort path: the OS CSPRNG is unavailable (should never happen
        // on a shipping device). Seed a PRNG from the FULL width of
        // random_device by drawing it 32 bits at a time rather than once, so
        // even this degraded path does not inherit the 2^32 seed defect.
        std::random_device rd;
        auto draw64 = [&rd]() -> uint64_t {
            uint64_t v = 0;
            for (int i = 0; i < 64; i += 32)
                v = (v << 32) | (uint64_t)rd();
            return v;
        };
        std::mt19937_64 gen{draw64()};
        std::uniform_int_distribution<uint64_t> dist;
        a = dist(gen);
        b = dist(gen);
    }

    // Set version (4) and variant (10xx) bits per RFC 4122. This spends 6 of
    // the 128 bits, leaving 122 bits of real entropy — now actually 122,
    // because the source above no longer funnels through a 32-bit seed.
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

std::string salt_tag(const std::string& salt) {
    if (salt.empty()) return "";
    // FNV-1a 64-bit. Chosen over SHA-256 because the core links only
    // sqlite3 + libc++ (see core/CMakeLists.txt) and this label is not a
    // security boundary — it namespaces ids, it does not protect them.
    uint64_t h = 1469598103934665603ULL;          // offset basis
    for (unsigned char c : salt) {
        h ^= static_cast<uint64_t>(c);
        h *= 1099511628211ULL;                    // prime
    }
    char buf[9];
    snprintf(buf, sizeof(buf), "%08x", (unsigned)(h >> 32));
    return std::string(buf);
}

std::string generate_session_id(const std::string& salt) {
    const std::string uuid = generate_uuid();
    const std::string tag  = salt_tag(salt);
    // Empty salt → byte-identical to the pre-salt format, so sessions already
    // in the warehouse keep parsing and nothing needs backfilling.
    if (tag.empty()) return uuid;
    return tag + "-" + uuid;
}

int64_t current_time_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(
        system_clock::now().time_since_epoch()).count();
}

} // namespace unitrack
