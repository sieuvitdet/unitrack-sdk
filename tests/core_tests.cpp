// Minimal test runner for the C++ core. No framework — keeps the build
// surface tiny. Each test logs PASS/FAIL and the runner returns non-zero
// on any failure.

#include "../core/include/unitrack/unitrack.h"
#include "../core/src/event.h"
#include "../core/src/util.h"
#include "../core/src/offline_queue.h"
#include "../core/src/config.h"
#include "../core/src/crash_handler.h"
#include "../core/src/session_manager.h"
#include "../core/src/trace_context.h"

#include <sqlite3.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
#include <set>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <chrono>
#include <atomic>

static int    g_failed = 0;
static int    g_passed = 0;

#define CHECK(cond, msg) do { \
    if (cond) { ++g_passed; printf("  PASS: %s\n", msg); } \
    else      { ++g_failed; printf("  FAIL: %s  (line %d)\n", msg, __LINE__); } \
} while (0)

// ─── tests ─────────────────────────────────────────────────────────────────

static void test_uuid() {
    printf("test_uuid\n");
    auto a = unitrack::generate_uuid();
    auto b = unitrack::generate_uuid();
    CHECK(a.size() == 36, "uuid length 36");
    CHECK(a != b, "uuids unique");
    CHECK(a[14] == '4', "uuid v4 marker");
}

// Helper: chuỗi chỉ chứa hex chữ thường?
static bool is_lower_hex(const char* s, size_t n) {
    for (size_t i = 0; i < n; ++i) {
        char c = s[i];
        bool ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
        if (!ok) return false;
    }
    return true;
}

static void test_trace_context() {
    printf("test_trace_context\n");

    // C++ helper trực tiếp.
    auto a = unitrack::new_trace();
    auto b = unitrack::new_trace();
    CHECK(std::strlen(a.trace_id) == 32, "trace_id 32 hex chars");
    CHECK(std::strlen(a.span_id)  == 16, "span_id 16 hex chars");
    CHECK(is_lower_hex(a.trace_id, 32),  "trace_id is lowercase hex");
    CHECK(is_lower_hex(a.span_id,  16),  "span_id is lowercase hex");
    CHECK(std::string(a.trace_id) != std::string(b.trace_id), "trace_ids unique");
    CHECK(std::string(a.span_id)  != std::string(b.span_id),  "span_ids unique");

    // W3C cấm all-zero — kiểm tra trace_id KHÔNG phải toàn '0'.
    CHECK(std::string(a.trace_id) != std::string(32, '0'), "trace_id not all-zero");
    CHECK(std::string(a.span_id)  != std::string(16, '0'), "span_id not all-zero");

    // Header format: "00-<trace>-<span>-<flags>" — đúng 55 ký tự, sampled=01.
    auto hdr = unitrack::traceparent_header(a, /*sampled=*/true);
    CHECK(hdr.size() == 55, "traceparent length 55");
    CHECK(hdr.substr(0, 3) == "00-", "starts with version 00");
    CHECK(hdr.substr(3, 32) == std::string(a.trace_id), "embeds trace_id");
    CHECK(hdr[35] == '-' && hdr.substr(36, 16) == std::string(a.span_id), "embeds span_id");
    CHECK(hdr.substr(53, 2) == "01", "flags 01 when sampled");
    CHECK(unitrack::traceparent_header(a, /*sampled=*/false).substr(53, 2) == "00",
          "flags 00 when not sampled");

    // C API: ut_new_trace + ut_format_traceparent.
    ut_trace_ids ids = ut_new_trace();
    CHECK(std::strlen(ids.trace_id) == 32, "C API: trace_id 32 hex");
    CHECK(std::strlen(ids.span_id)  == 16, "C API: span_id 16 hex");

    char buf[64] = {0};
    size_t n = ut_format_traceparent(&ids, /*sampled=*/1, buf, sizeof(buf));
    CHECK(n == 55, "ut_format_traceparent returns 55");
    CHECK(std::string(buf).size() == 55, "buffer contains 55-char header");
    CHECK(std::string(buf).find(ids.trace_id) == 3, "header embeds id at offset 3");

    // Buffer quá nhỏ ⇒ trả 0, không ghi đè (an toàn cho binding lỡ truyền 32).
    char tiny[32] = {0};
    size_t m = ut_format_traceparent(&ids, 1, tiny, sizeof(tiny));
    CHECK(m == 0, "ut_format_traceparent refuses small buffer");
    CHECK(tiny[0] == 0, "small buffer untouched");
}

static void test_event_json() {
    printf("test_event_json\n");
    unitrack::Event e;
    e.event_id        = "id-1";
    e.event_name      = "tap";
    e.timestamp_ms    = 1700000000000LL;
    e.session_id      = "sess-1";
    e.user_id         = "u-1";
    e.screen          = "Home";
    e.properties_json = "{\"x\":1}";
    auto s = e.to_json();
    CHECK(s.find("\"event_id\":\"id-1\"")  != std::string::npos, "has event_id");
    CHECK(s.find("\"event_name\":\"tap\"") != std::string::npos, "has event_name");
    CHECK(s.find("\"properties\":{\"x\":1}") != std::string::npos, "merges props");
}

static void test_event_json_escape() {
    printf("test_event_json_escape\n");
    unitrack::Event e;
    e.event_id     = "id";
    e.event_name   = "bad\"name\\with\nnewline";
    e.timestamp_ms = 1;
    auto s = e.to_json();
    CHECK(s.find("\\\"") != std::string::npos, "escapes quotes");
    CHECK(s.find("\\\\") != std::string::npos, "escapes backslash");
    CHECK(s.find("\\n")  != std::string::npos, "escapes newline");
}

static void test_config_parse() {
    printf("test_config_parse\n");
    auto c = unitrack::Config::from_json("KEY",
        "{\"endpoint\":\"https://x/y\",\"batch_size\":7,\"sampling_rate\":0.5,"
        "\"enabled\":false}");
    CHECK(c.api_key       == "KEY",            "api_key");
    CHECK(c.endpoint      == "https://x/y",    "endpoint");
    CHECK(c.batch_size    == 7,                "batch_size");
    CHECK(c.sampling_rate == 0.5,              "sampling_rate");
    CHECK(c.enabled       == false,            "enabled false");

    auto d = unitrack::Config::from_json("K", "");
    CHECK(d.api_key   == "K",               "defaults: api_key");
    CHECK(d.batch_size == 50,               "defaults: batch_size");
    CHECK(d.enabled    == true,             "defaults: enabled");
    CHECK(d.journey_capture == true,        "defaults: journey_capture on");
    CHECK(d.session_timeout_ms == 30*60*1000, "defaults: session_timeout 30m");

    auto j = unitrack::Config::from_json("K",
        "{\"journey_capture\":false,\"session_timeout_ms\":60000}");
    CHECK(j.journey_capture == false,       "journey_capture parsed false");
    CHECK(j.session_timeout_ms == 60000,    "session_timeout_ms parsed");
}

static void test_offline_queue() {
    printf("test_offline_queue\n");
    std::remove("/tmp/ut_test_queue.db");
    {
        unitrack::OfflineQueue q("/tmp/ut_test_queue.db");
        unitrack::Event e;
        e.event_id     = "evt-1";
        e.event_name   = "tap";
        e.timestamp_ms = 100;
        e.session_id   = "s";
        e.screen       = "Home";
        e.properties_json = "{}";
        CHECK(q.enqueue(e),                       "enqueue");
        // Duplicate event_id should be ignored.
        CHECK(q.enqueue(e),                       "enqueue dup (INSERT OR IGNORE)");
        CHECK(q.count() == 1,                     "count == 1");

        e.event_id = "evt-2";
        q.enqueue(e);
        CHECK(q.count() == 2,                     "count == 2");

        auto peek = q.peek(10);
        CHECK(peek.size() == 2,                   "peek size");
        CHECK(peek[0].event.event_id == "evt-1",  "peek order");

        q.remove({peek[0].row_id, peek[1].row_id});
        CHECK(q.count() == 0,                     "remove all");
    }
    std::remove("/tmp/ut_test_queue.db");
    std::remove("/tmp/ut_test_queue.db-shm");
    std::remove("/tmp/ut_test_queue.db-wal");
}

// Migration: opening a PRE-backoff database (events table without next_retry_at)
// must add the column and let peek() work — not crash with "no such column".
static void test_schema_migration() {
    printf("test_schema_migration\n");
    const char* db = "/tmp/ut_test_oldschema.db";
    std::remove(db);
    // 1) Create an old-schema events table (no next_retry_at) + a row.
    sqlite3* h = nullptr;
    sqlite3_open(db, &h);
    sqlite3_exec(h, "CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT,"
                    " event_id TEXT UNIQUE NOT NULL, created_at INTEGER NOT NULL,"
                    " payload TEXT NOT NULL, retry_count INTEGER NOT NULL DEFAULT 0);",
                 nullptr, nullptr, nullptr);
    sqlite3_exec(h, "INSERT INTO events (event_id,created_at,payload) VALUES ('old1',100,'{}');",
                 nullptr, nullptr, nullptr);
    sqlite3_close(h);
    // 2) Open via OfflineQueue → should migrate; peek() must not error.
    {
        unitrack::OfflineQueue q(db);
        auto rows = q.peek(10);
        CHECK(rows.size() == 1, "migration: peek works on migrated old DB");
        CHECK(q.count() == 1,   "migration: old row preserved");
    }
    std::remove(db);
    std::remove("/tmp/ut_test_oldschema.db-shm");
    std::remove("/tmp/ut_test_oldschema.db-wal");
}

// Exponential backoff: a failed event is kept (count unchanged) but hidden from
// peek() until its backoff window elapses; once due it becomes visible again.
static void test_backoff() {
    printf("test_backoff\n");
    std::remove("/tmp/ut_test_backoff.db");
    {
        unitrack::OfflineQueue q("/tmp/ut_test_backoff.db");
        // Use a real "now" timestamp so the age-based trim (7 days) doesn't
        // sweep these events away during the max_retries check below.
        const int64_t now = unitrack::current_time_ms();
        unitrack::Event e;
        e.event_id = "evt-b1"; e.event_name = "tap"; e.timestamp_ms = now;
        e.properties_json = "{}";
        q.enqueue(e);

        auto due = q.peek(10);
        CHECK(due.size() == 1,                    "backoff: due before failure");

        // Fail it with a long base delay → should be hidden from peek but kept.
        q.mark_retry({due[0].row_id}, /*base*/100000, /*max*/300000);
        CHECK(q.count() == 1,                     "backoff: event kept after fail");
        CHECK(q.peek(10).empty(),                 "backoff: hidden until next_retry_at");

        // A freshly enqueued event is due immediately (next_retry_at = 0).
        unitrack::Event e2;
        e2.event_id = "evt-b2"; e2.event_name = "tap"; e2.timestamp_ms = now;
        e2.properties_json = "{}";
        q.enqueue(e2);
        auto due2 = q.peek(10);
        bool sawB2 = false;
        for (auto& d : due2) if (d.event.event_id == "evt-b2") sawB2 = true;
        CHECK(sawB2,                              "backoff: new event still due");

        // After max_retries, evt-b1 is dropped by trim; evt-b2 (0 retries) stays.
        for (int i = 0; i < 12; ++i) q.mark_retry({due[0].row_id}, 1, 1);
        q.trim(/*max_size*/10000, /*max_age_days*/7, /*max_retries*/10);
        CHECK(q.count() == 1,                     "backoff: dropped after max_retries");
    }
    std::remove("/tmp/ut_test_backoff.db");
    std::remove("/tmp/ut_test_backoff.db-shm");
    std::remove("/tmp/ut_test_backoff.db-wal");
}

// Counts HTTP calls received by mock transport.
static std::atomic<int> g_http_calls{0};
static std::string      g_last_payload;
static int mock_http(const char* /*url*/, const char* /*method*/,
                     const char* /*headers*/, const char* body, size_t len,
                     void* /*ud*/) {
    g_http_calls.fetch_add(1);
    g_last_payload.assign(body, len);
    return 200;
}

static void test_c_api_end_to_end() {
    printf("test_c_api_end_to_end\n");
    std::remove("/tmp/ut_e2e.db");

    g_http_calls.store(0);
    g_last_payload.clear();

    const char* cfg =
        "{\"db_path\":\"/tmp/ut_e2e.db\","
        " \"batch_size\":3,"
        " \"flush_interval_ms\":100,"
        " \"screen_lifecycle\":false,"   // this test checks track/tap/net, not screen events
        " \"sampling_rate\":1.0}";
    ut_context* ctx = ut_init("test-key", cfg, UT_PLATFORM_IOS);
    CHECK(ctx != nullptr, "ut_init");
    ut_set_http_transport(ctx, mock_http, nullptr);

    ut_set_screen(ctx, "Home");
    ut_track(ctx, "button_clicked", "{\"label\":\"buy\"}");
    ut_log_tap(ctx, "buy_btn", "Home", "{}");
    ut_log_network(ctx, "https://api.example.com/x", "GET", 200, 123, 0, 456, "");
    ut_log_json_error(ctx, "User", "missing field", "stack", "{\"id\":1");

    // Trigger flush (we have >3 events).
    ut_flush(ctx);

    // Wait for background worker to send.
    for (int i = 0; i < 30 && g_http_calls.load() == 0; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    CHECK(g_http_calls.load() >= 1, "HTTP send happened");
    CHECK(g_last_payload.front() == '[' && g_last_payload.back() == ']',
          "payload is JSON array");
    CHECK(g_last_payload.find("button_clicked") != std::string::npos,
          "payload contains tracked event");

    ut_shutdown(ctx);
    std::remove("/tmp/ut_e2e.db");
    std::remove("/tmp/ut_e2e.db-shm");
    std::remove("/tmp/ut_e2e.db-wal");
}

static void test_crash_handler_flush() {
    printf("test_crash_handler_flush\n");
    // Write a fake crash file by hand, then verify flush_pending_crash
    // reads + deletes it.
    const char* dir = "/tmp/ut_crash_test";
    mkdir(dir, 0700);
    FILE* fp = fopen("/tmp/ut_crash_test/crash-pending.json", "w");
    CHECK(fp != nullptr, "open crash file");
    fputs("{\"signal\":11,\"signal_name\":\"SIGSEGV\"}", fp);
    fclose(fp);

    auto s = unitrack::CrashHandler::flush_pending_crash(dir);
    CHECK(s.find("SIGSEGV") != std::string::npos, "crash JSON read");

    // File should be deleted now.
    FILE* p2 = fopen("/tmp/ut_crash_test/crash-pending.json", "r");
    CHECK(p2 == nullptr, "crash file deleted after flush");
    if (p2) fclose(p2);

    rmdir(dir);
}

static void test_session_boundary() {
    printf("test_session_boundary\n");
    using namespace unitrack;

    // Short timeout so we can force a rotation without sleeping 30 min.
    SessionManager sm;
    sm.set_timeout_ms(50);

    // First resolve: current session, no rotation reported (it's the initial
    // session the manager created in its constructor).
    SessionResolution a = sm.resolve();
    CHECK(!a.id.empty(), "session: initial id present");
    CHECK(!a.rotated, "session: first resolve is not a rotation");
    std::string first_id = a.id;

    // Activity within the window keeps the same session.
    SessionResolution b = sm.resolve();
    CHECK(b.id == first_id, "session: stays same within timeout");
    CHECK(!b.rotated, "session: no rotation within timeout");

    // Let the timeout elapse → next resolve rotates and reports the boundary.
    std::this_thread::sleep_for(std::chrono::milliseconds(80));
    SessionResolution c = sm.resolve(SessionEndReason::timeout);
    CHECK(c.rotated, "session: rotated after timeout");
    CHECK(c.id != first_id, "session: new id after rotation");
    CHECK(c.prev_id == first_id, "session: prev_id is the closed session");
    CHECK(c.prev_reason == SessionEndReason::timeout, "session: end reason timeout");
    CHECK(c.prev_ended_ms >= c.prev_started_ms, "session: end >= start");

    // Boundary is consumed — the following resolve reports no rotation.
    SessionResolution d = sm.resolve();
    CHECK(!d.rotated, "session: boundary consumed once");
    CHECK(d.id == c.id, "session: id stable after consuming boundary");

    // Manual rotate (reset) reports manual_reset on the next resolve.
    sm.rotate(SessionEndReason::manual_reset);
    SessionResolution e = sm.resolve(SessionEndReason::timeout);
    CHECK(e.rotated, "session: manual rotate reported");
    CHECK(e.prev_reason == SessionEndReason::manual_reset, "session: manual_reset reason preserved");
}

// Screen lifecycle: switching screens should emit screen_end (for the screen
// being left, with dwell_ms) + screen_view + screen_start (for the new one),
// and the start/end event names must be renameable via config.
static void test_screen_lifecycle() {
    printf("test_screen_lifecycle\n");
    std::remove("/tmp/ut_screen.db");
    g_http_calls.store(0);
    g_last_payload.clear();

    // Rename the lifecycle events to a custom taxonomy.
    const char* cfg =
        "{\"db_path\":\"/tmp/ut_screen.db\","
        " \"batch_size\":50,"          // hold everything in one batch
        " \"flush_interval_ms\":100,"
        " \"screen_lifecycle\":true,"
        " \"screen_start_event\":\"page_enter\","
        " \"screen_end_event\":\"page_leave\","
        " \"sampling_rate\":1.0}";
    ut_context* ctx = ut_init("test-key", cfg, UT_PLATFORM_IOS);
    CHECK(ctx != nullptr, "screen: ut_init");
    ut_set_http_transport(ctx, mock_http, nullptr);

    ut_set_screen(ctx, "Home");                 // first screen: enter only
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    ut_set_screen(ctx, "Detail");               // leave Home (+dwell), enter Detail
    ut_set_screen(ctx, "Detail");               // same screen → no event
    ut_flush(ctx);

    for (int i = 0; i < 30 && g_http_calls.load() == 0; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(50));

    const std::string& p = g_last_payload;
    CHECK(g_http_calls.load() >= 1, "screen: HTTP send happened");
    CHECK(p.find("page_enter") != std::string::npos, "screen: renamed start event present");
    CHECK(p.find("page_leave") != std::string::npos, "screen: renamed end event present");
    CHECK(p.find("\"screen_start\"") == std::string::npos, "screen: default start name NOT used");
    CHECK(p.find("dwell_ms") != std::string::npos, "screen: end carries dwell_ms");
    CHECK(p.find("screen_view") != std::string::npos, "screen: screen_view kept for back-compat");
    // Home should have a leave event; Detail should have an enter event.
    CHECK(p.find("\"screen\":\"Home\"") != std::string::npos, "screen: Home tracked");
    CHECK(p.find("\"from\":\"Home\"") != std::string::npos, "screen: Detail start records from=Home");

    ut_shutdown(ctx);
    std::remove("/tmp/ut_screen.db");
    std::remove("/tmp/ut_screen.db-shm");
    std::remove("/tmp/ut_screen.db-wal");
}

// Cross-language layer registry: register flips bits, claim_subtree round-trips,
// release removes. Idempotent register doesn't double-count.
// UUID entropy. Guards the defect that put session 41ce987d on two different
// handsets: generate_uuid() used to seed a mt19937_64 from ONE
// std::random_device{}() call, and that type is 32 bits wide on every platform
// we ship. The whole id stream was therefore a function of 2^32 possible seeds,
// so two devices collided after ~65k cold starts (measured: 61,305).
//
// This test cannot prove global uniqueness — nothing can — but it fails loudly
// if the entropy source is ever narrowed again: a 32-bit-seeded generator
// produces detectable structure across a large sample, and identical output
// when two generators start from the same seed.
static void test_uuid_entropy() {
    printf("test_uuid_entropy\n");
    using namespace unitrack;

    // No duplicates across a large in-process sample.
    const int N = 200000;
    std::set<std::string> ids;
    for (int i = 0; i < N; ++i) ids.insert(generate_uuid());
    CHECK((int)ids.size() == N, "uuid: 200k ids all distinct");

    // Bit-level balance. With real entropy each of the 122 free bits is ~50/50.
    // A narrowed source skews this hard. Count set bits over the hex nibbles,
    // skipping the 6 bits RFC 4122 pins (version nibble + variant high bits).
    long long ones = 0, total = 0;
    for (int i = 0; i < 20000; ++i) {
        std::string u = generate_uuid();
        for (size_t p = 0; p < u.size(); ++p) {
            if (u[p] == '-') continue;
            if (p == 14) continue;              // version nibble, always '4'
            if (p == 19) continue;              // variant nibble, top bits pinned
            int v = (u[p] >= 'a') ? (u[p] - 'a' + 10) : (u[p] - '0');
            for (int b = 0; b < 4; ++b) { ones += (v >> b) & 1; total += 1; }
        }
    }
    double ratio = (double)ones / (double)total;
    CHECK(ratio > 0.49 && ratio < 0.51, "uuid: bit distribution is balanced");

    // Format still RFC 4122 v4 after the entropy-source change.
    std::string u = generate_uuid();
    CHECK(u.size() == 36, "uuid: length 36");
    CHECK(u[14] == '4', "uuid: version nibble is 4");
    CHECK(u[19]=='8'||u[19]=='9'||u[19]=='a'||u[19]=='b', "uuid: variant is 10xx");

    // Trace/span ids draw from the same source — no collisions at scale.
    std::set<uint64_t> tr;
    for (int i = 0; i < 50000; ++i) tr.insert(secure_random_u64());
    CHECK(tr.size() == 50000, "uuid: secure_random_u64 has no collisions in 50k");
}

// Session id namespace salt. The salt must namespace ids WITHOUT costing
// entropy: same salt => same 8-hex prefix, different salt => different prefix,
// empty salt => byte-identical to the old bare-UUID format, and the UUID part
// must still be unique every time.
// Headless launch (FCM push wake / job) must NOT open a session. A UI-less
// process has no user period of use; rotating there produced ~3-event phantom
// sessions and drove one prod device to session_index 1917.
// Regression: last_activity_ms must actually reach DISK as the session runs.
// It used to advance only in memory (stamp_for_event saved once, for the first
// event), so a relaunch read a value frozen at session start and measured the
// kill gap from the wrong instant — defeating KILL_GRACE_MS entirely. Measured
// on a real device 2026-08-20: 9 sessions in 17s despite gaps of 0.2s.
static void test_session_activity_persisted() {
    printf("test_session_activity_persisted\n");
    using namespace unitrack;
    const char* path = "/tmp/ut_test_activity_persist.json";
    std::remove(path);

    auto read_last_activity = [&]() -> long long {
        FILE* f = fopen(path, "r");
        if (!f) return -1;
        char buf[1024] = {0};
        size_t n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        (void)n;
        const char* k = strstr(buf, "\"last_activity_ms\":");
        if (!k) return -1;
        return atoll(k + strlen("\"last_activity_ms\":"));
    };

    std::string sid;
    long long started_at = 0;
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/false);
        sm.stamp_for_event("e1");
        sid = sm.current_session_id();
        started_at = read_last_activity();
        CHECK(started_at > 0, "activity persist: file written on first event");

        // Simulate a session that has been running a while, then one more
        // event. Before the fix this event never touched the file at all, so
        // the on-disk clock stayed frozen at the value e1 wrote.
        //
        // NOTE: assert on the value written, not on "it grew" — e1 and e2 land
        // in the same millisecond under test, so the fresh save legitimately
        // writes the same number. Rewinding only moves the in-memory copy
        // backwards; the save still stamps wall-clock now.
        sm.rewind_activity_for_test(30 * 1000);
        sm.stamp_for_event("e2");
        // In-memory clock must be back at now (not the rewound value).
        CHECK(sm.last_activity_for_test() >= started_at,
              "activity persist: e2 advanced the in-memory clock");
    }

    long long after = read_last_activity();
    CHECK(after >= started_at,
          "activity persist: later events persist last_activity_ms to disk");

    // And the whole point: a force-quit right after that event must resume,
    // because the measured gap is now tiny rather than session-long.
    {
        // A live session persists clean_shutdown:0 already — that is exactly
        // the state a force-quit leaves behind (mark_clean_shutdown never ran).
        FILE* f = fopen(path, "r");
        char buf[1024] = {0};
        size_t rd = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        (void)rd;
        CHECK(strstr(buf, "\"clean_shutdown\":0") != nullptr,
              "activity persist: a running session is on-disk unclean");

        // Under the 2026-08-21 rule every launch rotates, so the assertion
        // here is about the CHAIN, not about resuming: the relaunch must hand
        // the data team the session it just closed. The persisted clock still
        // matters — it is what stamps prev_ended_ms and picks the reason.
        SessionManager sm;
        sm.load_from(path, /*headless=*/false);
        CHECK(sm.current_session_id() != sid,
              "activity persist: relaunch mints a new session");
        CHECK(sm.previous_session_id() == sid,
              "activity persist: relaunch chains the closed session");
    }
    std::remove(path);
}

// Product-owner decision 2026-08-21: a notification DOES open a session.
// The previous headless exemption (60 pushes -> 1 session) is gone; each push
// past the timeout now rotates like any other launch, carrying its own
// session_started + user_context. This test pins the new contract so the
// exemption cannot creep back in silently.
// Product-owner decision 2026-08-21, restoring the old SDK rule: EVERY process
// launch opens a new session. Reaching load_from() means a new process started
// — the app was killed and reopened, or FCM woke it — and both mint a fresh
// session regardless of gap length or clean_shutdown.
//
// This supersedes KILL_GRACE_MS (0.3.63), which resumed on a quick relaunch.
// The constant still exists but no longer gates load_from(); timeout_ms_ now
// only decides the REASON stamped on the closing session, and still drives the
// lazy rotate inside a running process (stamp_for_event / resolve).
// Noti tới lúc app nằm background phải KHÔNG gia hạn phiên.
//
// Process vẫn sống nên event đi qua stamp_for_event(), không qua load_from(),
// và isHeadlessLaunch() trả false — SDK không tự phân biệt được, host bật cờ.
// Đo 2026-08-21 trên Xiaomi: app background từ 14:30, noti cách nhau 8-33s,
// mỗi cái reset đồng hồ 30', nên mở app lúc 15:10 (sau 40') vẫn không rotate
// (session 5af4f97b sống 38' với max gap 95.8s).
static void test_background_activity_does_not_extend() {
    printf("test_background_activity_does_not_extend\n");
    using namespace unitrack;
    const char* path = "/tmp/ut_test_bg_activity.json";

    // Với cờ BẬT: 6 noti trải 30 phút không được giữ session sống.
    std::remove(path);
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/false);
        const std::string sid0 = sm.current_session_id();
        sm.set_background_activity(true);
        // 7 x 5' = 35' > timeout. Sáu bước chỉ chạm đúng 30' — biên `>` chưa
        // vượt — nên phải đi quá hẳn để khẳng định hết hạn, không phải đứng
        // ngay mép. Không gọi current_session_id() trong vòng lặp: accessor đó
        // cũng rotate, làm mốc hết hạn phụ thuộc số lần đọc.
        for (int i = 0; i < 7; ++i) {
            sm.rewind_activity_for_test(5 * 60 * 1000);
            sm.stamp_for_event("noti");
        }
        sm.set_background_activity(false);
        CHECK(sm.current_session_id() != sid0,
              "bg activity: 35' of notifications still expires the session");
    }

    // Đối chứng — cùng chuỗi đó với cờ TẮT thì session sống (hành vi cũ),
    // chứng minh test đang đo đúng cái cờ chứ không phải thứ khác.
    std::remove(path);
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/false);
        const std::string sid0 = sm.current_session_id();
        for (int i = 0; i < 7; ++i) {
            sm.rewind_activity_for_test(5 * 60 * 1000);
            sm.stamp_for_event("tap");
        }
        CHECK(sm.current_session_id() == sid0,
              "bg activity: real interaction still renews the session");
    }

    // Cờ KHÔNG được chặn rotate: quá timeout thì vẫn phải mở session mới.
    std::remove(path);
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/false);
        const std::string sid0 = sm.current_session_id();
        sm.set_background_activity(true);
        sm.rewind_activity_for_test(31 * 60 * 1000);
        sm.stamp_for_event("noti");
        CHECK(sm.current_session_id() != sid0,
              "bg activity: a notification past the timeout still rotates");
    }
    std::remove(path);
}

// last_end_reason() phải sống sót qua resolve(): prev_reason_ bị resolve()
// tiêu thụ ngay khi emit boundary, nhưng binding đọc reason TRONG handler
// onSessionRotate — tức là sau đó. Hardcode "timeout" ở tầng app (cách cũ)
// làm logout và hết-hạn-30' trông giống hệt nhau với đội Data.
static void test_last_end_reason_survives_resolve() {
    printf("test_last_end_reason_survives_resolve\n");
    using namespace unitrack;
    const char* path = "/tmp/ut_test_end_reason.json";
    std::remove(path);

    SessionManager sm;
    sm.load_from(path, /*headless=*/false);
    CHECK(sm.last_end_reason() == SessionEndReason::none,
          "end reason: none trước lần rotate đầu");

    // Logout.
    sm.rotate(SessionEndReason::manual_reset);
    CHECK(sm.last_end_reason() == SessionEndReason::manual_reset,
          "end reason: manual_reset sau rotate");
    // resolve() tiêu thụ pending_boundary_ — reason vẫn phải đọc được sau đó.
    sm.resolve(SessionEndReason::timeout);
    CHECK(sm.last_end_reason() == SessionEndReason::manual_reset,
          "end reason: sống sót qua resolve()");

    // Lần rotate kế tiếp ghi đè.
    sm.rotate(SessionEndReason::timeout);
    CHECK(sm.last_end_reason() == SessionEndReason::timeout,
          "end reason: rotate sau ghi đè reason cũ");
    std::remove(path);
}

static void test_every_launch_rotates() {
    printf("test_every_launch_rotates\n");
    using namespace unitrack;
    const char* path = "/tmp/ut_test_every_launch.json";
    const std::string ORIG = "aaaaaaaa-0000-0000-0000-000000000001";

    auto seed = [&](int64_t gap_ms, int clean) {
        std::remove(path);
        int64_t last = current_time_ms() - gap_ms;
        FILE* f = fopen(path, "w");
        fprintf(f, "{\"session_id\":\"%s\",\"session_index\":5,"
                   "\"started_at_ms\":%lld,\"last_activity_ms\":%lld,"
                   "\"previous_session_id\":\"\",\"clean_shutdown\":%d}",
                ORIG.c_str(), (long long)(last - 60000), (long long)last, clean);
        fclose(f);
    };

    // Every combination of gap x clean_shutdown rotates. 1s/unclean used to
    // resume under KILL_GRACE_MS; a clean 20s background used to resume too.
    struct Case { int64_t gap; int clean; const char* what; };
    const Case cases[] = {
        {1000,             0, "1s unclean"},
        {9000,             0, "9s unclean"},
        {20000,            0, "20s unclean"},
        {20000,            1, "20s clean"},
        {31 * 60 * 1000,   0, "31min unclean"},
        {31 * 60 * 1000,   1, "31min clean"},
    };
    for (const auto& c : cases) {
        seed(c.gap, c.clean);
        SessionManager sm;
        sm.load_from(path, /*headless=*/false);
        CHECK(sm.current_session_id() != ORIG,   "every launch rotates: new id");
        CHECK(sm.current_session_index() == 6,   "every launch rotates: index bumped");
        CHECK(sm.previous_session_id() == ORIG,  "every launch rotates: prev chained");
    }
    std::remove(path);
}

// Noti KHÔNG phải một phiên sử dụng — quyết định 2026-09-04, thu hẹp rule
// "mỗi lần kích hoạt là một session" của 2026-08-21.
//
// Process do FCM đánh thức nối lại session đã persist: giữ nguyên session_id
// và session_index. Rule cũ biến 60 noti thành 60 session, đẩy session_index
// tăng vọt vì những lần user không hề chạm vào app.
//
// Ngoại lệ vẫn giữ: gap vượt timeout thì rotate, vì session phải là một quãng
// liền mạch — nếu không, noti 8h sáng và noti 8h tối cùng mang một session_id
// và session đó không bao giờ đóng chừng nào user còn nhận noti mà không mở
// app.
static void test_headless_resumes_within_timeout() {
    printf("test_headless_resumes_within_timeout\n");
    using namespace unitrack;
    const char* path = "/tmp/ut_test_headless_resume.json";
    const std::string ORIG = "cccccccc-0000-0000-0000-000000000003";
    const std::string PREV = "dddddddd-0000-0000-0000-000000000004";

    // Ghi state với last_activity cách đây `gap_ms`.
    auto seed = [&](int64_t gap_ms) {
        std::remove(path);
        int64_t last = current_time_ms() - gap_ms;
        FILE* f = fopen(path, "w");
        fprintf(f, "{\"session_id\":\"%s\",\"session_index\":7,"
                   "\"started_at_ms\":%lld,\"last_activity_ms\":%lld,"
                   "\"previous_session_id\":\"%s\",\"clean_shutdown\":1}",
                ORIG.c_str(), (long long)(last - 60000), (long long)last,
                PREV.c_str());
        fclose(f);
    };

    // Trong timeout: nối lại, không đụng gì.
    seed(10 * 60 * 1000);
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/true);
        CHECK(sm.current_session_id() == ORIG,
              "headless within timeout resumes the stored session id");
        CHECK(sm.current_session_index() == 7,
              "headless within timeout leaves the index alone");
        CHECK(sm.previous_session_id() == PREV,
              "headless within timeout keeps the stored previous id");
    }

    // Ngay sát biên (29') vẫn nối lại.
    seed(29 * 60 * 1000);
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/true);
        CHECK(sm.current_session_index() == 7,
              "headless just under the timeout still resumes");
    }

    // Quá timeout: rotate như mọi launch khác.
    seed(45 * 60 * 1000);
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/true);
        CHECK(sm.current_session_id() != ORIG,
              "headless past timeout mints a new session");
        CHECK(sm.current_session_index() == 8,
              "headless past timeout bumps the index");
        CHECK(sm.previous_session_id() == ORIG,
              "headless rotate chains previous_session_id for the data team");
    }

    // Đối chứng: cùng gap ngắn đó, launch do USER mở thì vẫn phải rotate.
    // Đây là thứ phân biệt "noti" với "user mở app" — nếu nhánh resume rò rỉ
    // sang launch thường thì session_index sẽ đứng im ở mọi lần mở app.
    seed(10 * 60 * 1000);
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/false);
        CHECK(sm.current_session_index() == 8,
              "user launch within timeout still rotates");
    }

    // Bất biến chính của bug: N noti liên tiếp không được đụng vào index, và
    // lần user mở app kế tiếp phải tăng tiếp — KHÔNG reset về 1.
    seed(1000);
    for (int i = 0; i < 60; ++i) {
        SessionManager sm;
        sm.load_from(path, /*headless=*/true);
    }
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/true);
        CHECK(sm.current_session_index() == 7,
              "60 notifications leave session_index untouched");
    }
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/false);
        CHECK(sm.current_session_index() == 8,
              "the user launch after 60 notifications resumes counting, not 1");
    }
    std::remove(path);
}

// promote_to_user_launch(): sửa lại một launch bị đoán nhầm là headless.
//
// Binding Android không biết chắc "user có mở app không" tại
// Application.onCreate() — importance chưa lên FOREGROUND khi app khởi động
// lại sau crash. Đo 2026-09-04 trên Xiaomi: sau crash lúc 12:52, MỌI event
// mang is_headless=true kể cả screen_view do user bấm, và session 31f1c995 bị
// đóng băng gần một tiếng vì load_from() cứ nối lại mãi.
//
// Nên binding mặc định headless (an toàn) rồi gọi promote khi Activity đầu
// tiên tới. Test này pin: promote PHẢI rotate khi session là bản nối lại, và
// KHÔNG được rotate thêm khi load_from() đã rotate sẵn.
static void test_promote_to_user_launch() {
    printf("test_promote_to_user_launch\n");
    using namespace unitrack;
    const char* path = "/tmp/ut_test_promote.json";
    const std::string ORIG = "eeeeeeee-0000-0000-0000-000000000005";

    auto seed = [&](int64_t gap_ms) {
        std::remove(path);
        int64_t last = current_time_ms() - gap_ms;
        FILE* f = fopen(path, "w");
        fprintf(f, "{\"session_id\":\"%s\",\"session_index\":7,"
                   "\"started_at_ms\":%lld,\"last_activity_ms\":%lld,"
                   "\"previous_session_id\":\"\",\"clean_shutdown\":1}",
                ORIG.c_str(), (long long)(last - 60000), (long long)last);
        fclose(f);
    };

    // Nối lại (headless, trong timeout) -> cờ resumed bật.
    seed(10 * 60 * 1000);
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/true);
        CHECK(sm.resumed_persisted_session(),
              "promote: resumed flag set khi noi lai session");
        CHECK(sm.current_session_index() == 7,
              "promote: chua promote thi index giu nguyen");

        // Activity xuất hiện -> Tracker rotate qua promote.
        sm.rotate(SessionEndReason::killed_recovered);
        CHECK(sm.current_session_index() == 8,
              "promote: rotate bumps index cho user launch that");
        CHECK(sm.previous_session_id() == ORIG,
              "promote: previous_session_id chuoi ve session vua noi lai");
        CHECK(!sm.resumed_persisted_session(),
              "promote: rotate xoa co resumed");
    }

    // load_from đã rotate sẵn (gap vượt timeout) -> cờ KHÔNG bật, promote sẽ
    // không rotate thêm nên không đẻ session rỗng.
    seed(45 * 60 * 1000);
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/true);
        CHECK(!sm.resumed_persisted_session(),
              "promote: gap qua timeout thi load_from rotate, khong phai noi lai");
        CHECK(sm.current_session_index() == 8,
              "promote: index da bump san o load_from");
    }

    // User launch bình thường cũng không phải bản nối lại.
    seed(10 * 60 * 1000);
    {
        SessionManager sm;
        sm.load_from(path, /*headless=*/false);
        CHECK(!sm.resumed_persisted_session(),
              "promote: user launch khong bao gio la ban noi lai");
    }
    std::remove(path);
}

static void test_session_id_salt() {
    printf("test_session_id_salt\n");
    using namespace unitrack;

    // Empty salt = no tag = unchanged format (36-char UUID). This is what keeps
    // every session already in the warehouse valid.
    std::string bare = generate_session_id("");
    CHECK(bare.size() == 36, "salt: empty salt keeps bare uuid length");
    CHECK(salt_tag("").empty(), "salt: empty salt yields empty tag");

    // Deterministic per salt — the whole point of a namespace tag.
    CHECK(salt_tag("fli-beta") == salt_tag("fli-beta"), "salt: tag is deterministic");
    CHECK(salt_tag("fli-beta") != salt_tag("fli-prod"), "salt: different salt, different tag");
    CHECK(salt_tag("fli-beta").size() == 8, "salt: tag is 8 hex chars");

    // Tagged form: "<8 hex>-<36 char uuid>" and the tag matches salt_tag().
    std::string tagged = generate_session_id("fli-beta");
    CHECK(tagged.size() == 45, "salt: tagged id is tag(8) + '-' + uuid(36)");
    CHECK(tagged.compare(0, 8, salt_tag("fli-beta")) == 0, "salt: id carries the salt tag");
    CHECK(tagged[8] == '-', "salt: tag separated by dash");

    // Entropy preserved: the uuid tail must still differ across calls, and two
    // ids under the SAME salt must not collide. If the salt were mixed into the
    // random state instead of prefixed, this is what would break.
    std::string a = generate_session_id("fli-beta");
    std::string b = generate_session_id("fli-beta");
    CHECK(a != b, "salt: same salt still yields unique ids");
    CHECK(a.substr(9) != b.substr(9), "salt: uuid tail keeps full entropy");

    // The uuid tail is still a well-formed v4 (version nibble + variant).
    CHECK(tagged[23] == '4', "salt: uuid tail keeps version 4");
}

static void test_layer_registry() {
    printf("test_layer_registry\n");
    std::remove("/tmp/ut_layer.db");
    const char* cfg = "{\"db_path\":\"/tmp/ut_layer.db\","
                      " \"batch_size\":50, \"flush_interval_ms\":1000,"
                      " \"screen_lifecycle\":false, \"sampling_rate\":1.0}";
    ut_context* ctx = ut_init("test-key", cfg, UT_PLATFORM_IOS);
    CHECK(ctx != nullptr, "layer: ut_init");

    CHECK(ut_active_layers(ctx) == 0, "layer: empty before any register");

    ut_register_layer(ctx, UT_LAYER_NATIVE_IOS);
    ut_register_layer(ctx, UT_LAYER_FLUTTER);
    ut_register_layer(ctx, UT_LAYER_FLUTTER);  // idempotent
    uint32_t mask = ut_active_layers(ctx);
    CHECK((mask & UT_LAYER_NATIVE_IOS) != 0, "layer: iOS bit set");
    CHECK((mask & UT_LAYER_FLUTTER)    != 0, "layer: Flutter bit set");
    CHECK((mask & UT_LAYER_REACT_NATIVE) == 0, "layer: RN bit NOT set");

    // Subtree claim round-trip.
    CHECK(ut_subtree_claimed_by(ctx, "vc-42") == UT_LAYER_NONE,
          "layer: subtree unclaimed by default");
    ut_claim_subtree(ctx, UT_LAYER_FLUTTER, "vc-42");
    CHECK(ut_subtree_claimed_by(ctx, "vc-42") == UT_LAYER_FLUTTER,
          "layer: claim_subtree records owner");
    ut_release_subtree(ctx, "vc-42");
    CHECK(ut_subtree_claimed_by(ctx, "vc-42") == UT_LAYER_NONE,
          "layer: release_subtree clears owner");

    // Null / empty inputs are safe.
    ut_claim_subtree(ctx, UT_LAYER_FLUTTER, nullptr);
    ut_release_subtree(ctx, nullptr);
    CHECK(ut_subtree_claimed_by(ctx, nullptr) == UT_LAYER_NONE,
          "layer: null subtree_id safe");

    ut_shutdown(ctx);
    std::remove("/tmp/ut_layer.db");
    std::remove("/tmp/ut_layer.db-shm");
    std::remove("/tmp/ut_layer.db-wal");
}

// Cross-layer dedup: when iOS native swizzler and Flutter NavigatorObserver
// both call set_screen("Home") within the dedup window, only ONE screen_view
// reaches the queue. Different names → both pass through. Outside the window
// → both pass through. UT_LAYER_NONE never dedups (preserves legacy ut_set_screen).
static void test_screen_dedup_cross_layer() {
    printf("test_screen_dedup_cross_layer\n");
    std::remove("/tmp/ut_dedup.db");
    g_http_calls.store(0);
    g_last_payload.clear();

    const char* cfg = "{\"db_path\":\"/tmp/ut_dedup.db\","
                      " \"batch_size\":50, \"flush_interval_ms\":1000,"
                      " \"screen_lifecycle\":false, \"sampling_rate\":1.0}";
    ut_context* ctx = ut_init("test-key", cfg, UT_PLATFORM_IOS);
    CHECK(ctx != nullptr, "dedup: ut_init");
    ut_set_http_transport(ctx, mock_http, nullptr);
    ut_set_screen_dedup_window_ms(ctx, 250);

    // Count screen_view events for a given screen name. Each event JSON has
    // both an envelope `"screen":"X"` and a properties `"screen":"X"` — using
    // event_id occurrences in event objects whose `"screen":"<name>"` field
    // matches keeps the count = number of distinct events. Simplest robust
    // approach: count occurrences of the (event_name + screen) pair in the
    // batch JSON, where the pair only co-occurs once per event.
    auto count_screen_view = [](const std::string& payload, const std::string& screen) {
        // Pattern unique per event: "event_name":"screen_view" appears once
        // per event, then the same event carries "screen":"<name>" twice. We
        // count by splitting on event_id (one per event) and checking each
        // object for the matching screen.
        int n = 0;
        size_t p = 0;
        const std::string evid = "\"event_id\":";
        while ((p = payload.find(evid, p)) != std::string::npos) {
            // Find the end of this event object (next event_id or end-of-array).
            size_t next = payload.find(evid, p + evid.size());
            std::string obj = payload.substr(p, next == std::string::npos ? std::string::npos : next - p);
            if (obj.find("\"event_name\":\"screen_view\"") != std::string::npos &&
                obj.find("\"screen\":\"" + screen + "\"") != std::string::npos) {
                ++n;
            }
            p += evid.size();
        }
        return n;
    };

    // 1) Same name from two layers within the window → exactly 1 emission.
    ut_set_screen_for_layer(ctx, "Home", UT_LAYER_NATIVE_IOS);
    ut_set_screen_for_layer(ctx, "Home", UT_LAYER_FLUTTER);   // dedup-drop
    ut_flush(ctx);
    for (int i = 0; i < 30 && g_http_calls.load() == 0; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    CHECK(g_http_calls.load() >= 1, "dedup: HTTP send for first batch");
    CHECK(count_screen_view(g_last_payload, "Home") == 1,
          "dedup: same-name cross-layer collapsed to 1 screen_view");

    // 2) Different names → both pass through (no dedup).
    g_http_calls.store(0); g_last_payload.clear();
    ut_set_screen_for_layer(ctx, "Detail", UT_LAYER_NATIVE_IOS);
    ut_set_screen_for_layer(ctx, "OtherScreen", UT_LAYER_FLUTTER);
    ut_flush(ctx);
    for (int i = 0; i < 30 && g_http_calls.load() == 0; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    CHECK(count_screen_view(g_last_payload, "Detail") == 1, "dedup: Detail kept");
    CHECK(count_screen_view(g_last_payload, "OtherScreen") == 1,
          "dedup: OtherScreen kept (different name)");

    // 3) Outside the window: re-emit same name after window expires → both kept.
    g_http_calls.store(0); g_last_payload.clear();
    ut_set_screen_dedup_window_ms(ctx, 30);
    ut_set_screen_for_layer(ctx, "Profile", UT_LAYER_NATIVE_IOS);
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    // Intermediate spacer screen so Tracker's same-name-as-current dedup
    // (independent of layer) doesn't drop the second Profile call.
    ut_set_screen_for_layer(ctx, "Spacer", UT_LAYER_NATIVE_IOS);
    ut_set_screen_for_layer(ctx, "Profile", UT_LAYER_FLUTTER);  // outside window → kept
    ut_flush(ctx);
    for (int i = 0; i < 30 && g_http_calls.load() == 0; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    CHECK(count_screen_view(g_last_payload, "Profile") == 2,
          "dedup: re-emission outside window passes through");

    // 4) UT_LAYER_NONE never dedups (legacy ut_set_screen path).
    g_http_calls.store(0); g_last_payload.clear();
    ut_set_screen_dedup_window_ms(ctx, 250);
    ut_set_screen(ctx, "Legacy");
    ut_set_screen(ctx, "Spacer2");
    ut_set_screen(ctx, "Legacy");   // same name, both LAYER_NONE → not deduped by layer
    ut_flush(ctx);
    for (int i = 0; i < 30 && g_http_calls.load() == 0; ++i)
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    CHECK(count_screen_view(g_last_payload, "Legacy") == 2,
          "dedup: legacy ut_set_screen never cross-layer-deduped");

    ut_shutdown(ctx);
    std::remove("/tmp/ut_dedup.db");
    std::remove("/tmp/ut_dedup.db-shm");
    std::remove("/tmp/ut_dedup.db-wal");
}

int main() {
    printf("UniTrack core tests\n");
    printf("===================\n");
    test_uuid();
    test_trace_context();
    test_event_json();
    test_event_json_escape();
    test_config_parse();
    test_offline_queue();
    test_schema_migration();
    test_backoff();
    test_crash_handler_flush();
    test_session_boundary();
    test_screen_lifecycle();
    test_c_api_end_to_end();
    test_every_launch_rotates();
    test_last_end_reason_survives_resolve();
    test_background_activity_does_not_extend();
    test_session_activity_persisted();
    test_headless_resumes_within_timeout();
    test_promote_to_user_launch();
    test_layer_registry();
    test_screen_dedup_cross_layer();
    test_uuid_entropy();
    test_session_id_salt();

    printf("\nResult: %d passed, %d failed\n", g_passed, g_failed);
    return g_failed == 0 ? 0 : 1;
}
