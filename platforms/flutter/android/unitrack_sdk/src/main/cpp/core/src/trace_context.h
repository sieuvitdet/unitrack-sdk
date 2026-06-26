#pragma once

#include <cstdint>
#include <string>

namespace unitrack {

// W3C Trace Context generator.
//
// Mỗi outbound HTTP request từ app là một "span" mới trong một "trace".
// trace_id (128-bit) định danh chuỗi cuộc gọi xuyên hệ thống (app →
// gateway → service A → service B); span_id (64-bit) định danh một đoạn
// trong chuỗi đó. Backend đọc header `traceparent`, sinh span con dưới
// cùng trace_id → log app + log backend ráp lại bằng grep cùng id.
//
// Spec: https://www.w3.org/TR/trace-context/  Format header:
//   traceparent: 00-<trace 32 hex>-<span 16 hex>-<flags 2 hex>
//   ví dụ:       00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
//
// Tất cả hex chữ thường (spec yêu cầu); cả trace_id và span_id KHÔNG được
// toàn bit 0 — invalid theo spec. RNG kiểm tra và sinh lại nếu cần.
struct TraceIds {
    // Stored as lowercase hex without dashes. Sized for hex + NUL.
    char trace_id[33];   // 32 hex + '\0'
    char span_id[17];    // 16 hex + '\0'
};

// Sinh cặp (trace_id, span_id) hoàn toàn ngẫu nhiên — đại diện cho start
// của một chuỗi mới (root span). Thread-safe.
TraceIds new_trace();

// Format header value `00-<trace>-<span>-<flags>`. `sampled=true` ⇒ flags=01
// (backend nên ghi log), false ⇒ 00 (backend có thể bỏ qua).
std::string traceparent_header(const TraceIds& ids, bool sampled = true);

} // namespace unitrack
