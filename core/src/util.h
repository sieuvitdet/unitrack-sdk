#pragma once

#include <cstdint>
#include <string>

namespace unitrack {

// A cryptographically random 64-bit value straight from the OS entropy pool
// (getrandom / SecRandomCopyBytes / BCryptGenRandom).
//
// Use this for anything that must be globally unique across devices. Do NOT
// seed a std::mt19937* from a single std::random_device{}() call: that type is
// 32 bits wide on every platform we ship, which caps the generator at 2^32
// distinct streams and makes identical id sequences on two devices a ~65k-
// install event (this is a defect we already shipped once — see util.cpp).
uint64_t secure_random_u64();

// Generates a RFC4122 v4 UUID with 122 bits of OS-sourced entropy.
// Format: xxxxxxxx-xxxx-4xxx-Nxxx-xxxxxxxxxxxx
std::string generate_uuid();

// 8-hex namespace tag derived from a salt string, or "" when salt is empty.
// Used to prefix session ids so two tenants / app flavours writing into the
// same warehouse table can never collide, and so an id can be traced back to
// the config that produced it.
//
// NOT a security primitive and deliberately not a cryptographic hash: the core
// links only sqlite3 + libc++, and pulling OpenSSL onto four platforms to derive
// a namespace label is not worth it. FNV-1a is applied ONLY to the salt string
// itself — never to user data — so preimage resistance is not in the threat
// model. Salt secrecy buys nothing here and is not assumed.
std::string salt_tag(const std::string& salt);

// session_id = <salt_tag>-<uuid> when a salt is configured, else the bare uuid.
// The UUID keeps all 122 random bits either way: the tag is a PREFIX, never
// mixed into the entropy, so collision resistance is identical to a raw v4 and
// existing (untagged) ids stay valid.
std::string generate_session_id(const std::string& salt);

// Current time in milliseconds since Unix epoch. WALL CLOCK — nhảy khi hệ
// thống đồng bộ NTP hoặc user đổi giờ. Dùng cho TIMESTAMP (mốc gửi lên server)
// và cho mọi so sánh XUYÊN QUA lần app khởi động lại (session timeout, TTL
// hàng đợi offline) — những chỗ đó cần một trục thời gian chung giữa hai
// process, mà monotonic_ms() không cung cấp được.
int64_t current_time_ms();

// Đồng hồ đơn điệu, mili-giây kể từ một mốc tuỳ ý. Không bao giờ chạy lùi,
// không bị chỉnh giờ tác động. Dùng cho mọi phép đo KHOẢNG THỜI GIAN nằm gọn
// trong một process: dwell màn hình, cửa sổ dedup, throttle.
//
// KHÔNG dùng làm timestamp và KHÔNG ghi ra đĩa: mốc gốc reset mỗi lần process
// chạy lại nên giá trị vô nghĩa ở lần khởi động sau.
//
// Vì sao cần: dwell_ms tính bằng current_time_ms() ra -9.544.502ms trên
// iPhone thật (2026-09-02, session 0eeaebfc) khi iOS đồng bộ lại đồng hồ giữa
// lúc màn đang mở — máy ghi rời màn sớm hơn vào màn 2h39. Web đã gặp và sửa
// cùng lớp lỗi này (platforms/web/src/session.ts:40-49).
int64_t monotonic_ms();

} // namespace unitrack
