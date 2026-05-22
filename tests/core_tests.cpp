// Minimal test runner for the C++ core. No framework — keeps the build
// surface tiny. Each test logs PASS/FAIL and the runner returns non-zero
// on any failure.

#include "../core/include/unitrack/unitrack.h"
#include "../core/src/event.h"
#include "../core/src/util.h"
#include "../core/src/offline_queue.h"
#include "../core/src/config.h"
#include "../core/src/crash_handler.h"

#include <sys/stat.h>
#include <unistd.h>

#include <cstdio>
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

int main() {
    printf("UniTrack core tests\n");
    printf("===================\n");
    test_uuid();
    test_event_json();
    test_event_json_escape();
    test_config_parse();
    test_offline_queue();
    test_crash_handler_flush();
    test_c_api_end_to_end();

    printf("\nResult: %d passed, %d failed\n", g_passed, g_failed);
    return g_failed == 0 ? 0 : 1;
}
