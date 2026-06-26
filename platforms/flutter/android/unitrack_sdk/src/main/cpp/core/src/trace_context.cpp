#include "trace_context.h"

#include <cstdio>
#include <cstdint>
#include <random>

namespace unitrack {

namespace {

// thread_local RNG: tránh contention giữa nhiều thread (mỗi HTTP call có thể
// chạy trên worker khác nhau). Seed một lần bằng random_device — đủ tốt cho
// id không bí mật (không phải nonce mật mã, chỉ cần unique trong thực tế).
std::mt19937_64& rng() {
    static thread_local std::mt19937_64 gen{std::random_device{}()};
    return gen;
}

// Sinh 64-bit hex (16 ký tự), đảm bảo khác 0. W3C cấm span id all-zero.
uint64_t random_nonzero_u64() {
    std::uniform_int_distribution<uint64_t> dist;
    uint64_t v = 0;
    while (v == 0) v = dist(rng());
    return v;
}

void to_hex16(uint64_t v, char* out /* 17 bytes */) {
    // %016llx in tự dùng lowercase — đúng spec.
    std::snprintf(out, 17, "%016llx", (unsigned long long)v);
}

} // namespace

TraceIds new_trace() {
    TraceIds out{};
    // trace_id = ghép 2 lần 64-bit. Vòng lặp đảm bảo không bao giờ all-zero
    // (xác suất gần 0 nhưng phải bảo vệ — invalid theo spec).
    uint64_t hi = 0, lo = 0;
    while (hi == 0 && lo == 0) {
        std::uniform_int_distribution<uint64_t> dist;
        hi = dist(rng());
        lo = dist(rng());
    }
    char hi_hex[17], lo_hex[17];
    to_hex16(hi, hi_hex);
    to_hex16(lo, lo_hex);
    std::snprintf(out.trace_id, sizeof(out.trace_id), "%s%s", hi_hex, lo_hex);

    to_hex16(random_nonzero_u64(), out.span_id);
    return out;
}

std::string traceparent_header(const TraceIds& ids, bool sampled) {
    // version (00) + trace + span + flags. Tổng đúng 55 ký tự.
    char buf[64];
    std::snprintf(buf, sizeof(buf), "00-%s-%s-%s",
                  ids.trace_id, ids.span_id, sampled ? "01" : "00");
    return std::string(buf);
}

} // namespace unitrack
