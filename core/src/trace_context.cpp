#include "trace_context.h"
#include "util.h"

#include <cstdio>
#include <cstdint>

namespace unitrack {

namespace {

// Sinh 64-bit hex (16 ký tự), đảm bảo khác 0. W3C cấm span id all-zero.
//
// Lấy thẳng entropy từ OS (secure_random_u64) thay vì mt19937_64 seed bằng
// random_device{}(). random_device::result_type rộng 32 bit trên mọi platform
// SDK ship, nên seed 1 lần chỉ cho 2^32 stream — hai thiết bị trùng seed sẽ
// sinh ra dãy trace/span id giống hệt nhau. Trace id trùng làm hai request của
// hai máy khác nhau bị gộp thành một trace ở backend.
uint64_t random_nonzero_u64() {
    uint64_t v = 0;
    while (v == 0) v = secure_random_u64();
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
        hi = secure_random_u64();
        lo = secure_random_u64();
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
