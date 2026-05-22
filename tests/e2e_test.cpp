// End-to-end integration test.
// Spawns the Node backend, points the SDK at it via HTTP callback,
// tracks events, verifies they land in the backend DB.

#include "../core/include/unitrack/unitrack.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <chrono>
#include <atomic>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>

static int g_pass = 0, g_fail = 0;
#define CHECK(c, m) do { \
    if (c) { ++g_pass; printf("  PASS: %s\n", m); } \
    else   { ++g_fail; printf("  FAIL: %s\n", m); } \
} while (0)

// Tiny synchronous HTTP POST using raw sockets (no libcurl dep).
static int http_post(const char* host, int port, const char* path,
                     const char* headers_json,
                     const char* body, size_t body_len) {
    (void)headers_json;
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    inet_pton(AF_INET, host, &addr.sin_addr);
    if (connect(sock, (sockaddr*)&addr, sizeof(addr)) < 0) { close(sock); return -2; }

    char head[1024];
    int hlen = snprintf(head, sizeof(head),
        "POST %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Content-Type: application/json\r\n"
        "Authorization: Bearer e2e-key\r\n"
        "Content-Length: %zu\r\n"
        "Connection: close\r\n\r\n",
        path, host, port, body_len);
    if (send(sock, head, hlen, 0) < 0)         { close(sock); return -3; }
    if (send(sock, body, body_len, 0) < 0)     { close(sock); return -4; }

    char resp[256];
    ssize_t n = recv(sock, resp, sizeof(resp) - 1, 0);
    close(sock);
    if (n <= 0) return -5;
    resp[n] = 0;
    // Parse "HTTP/1.1 NNN"
    int status = 0;
    if (sscanf(resp, "HTTP/1.%*d %d", &status) != 1) return -6;
    return status;
}

static int g_endpoint_port = 18789;

// SDK transport callback — calls http_post.
static int sdk_http_cb(const char* /*url*/, const char* /*method*/,
                       const char* headers, const char* body, size_t len,
                       void* /*ud*/) {
    return http_post("127.0.0.1", g_endpoint_port, "/v1/events",
                     headers, body, len);
}

static bool wait_for_port(int port, int timeout_ms) {
    for (int i = 0; i < timeout_ms / 50; ++i) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_port   = htons(port);
        inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
        bool ok = connect(s, (sockaddr*)&a, sizeof(a)) == 0;
        close(s);
        if (ok) return true;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    return false;
}

// GET /v1/stats and return how many events the backend has.
static int backend_total() {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(g_endpoint_port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (connect(sock, (sockaddr*)&addr, sizeof(addr)) < 0) { close(sock); return -1; }

    const char* req =
        "GET /v1/stats HTTP/1.1\r\n"
        "Host: 127.0.0.1\r\n"
        "Authorization: Bearer e2e-key\r\n"
        "Connection: close\r\n\r\n";
    send(sock, req, strlen(req), 0);

    std::string resp;
    char buf[1024]; ssize_t n;
    while ((n = recv(sock, buf, sizeof(buf), 0)) > 0) {
        resp.append(buf, n);
    }
    close(sock);

    auto pos = resp.find("\"total\":");
    if (pos == std::string::npos) return -1;
    return std::atoi(resp.c_str() + pos + 8);
}

int main() {
    printf("UniTrack end-to-end test\n");
    printf("========================\n");

    // Spawn backend.
    char port_env[64];
    snprintf(port_env, sizeof(port_env), "PORT=%d", g_endpoint_port);
    pid_t pid = fork();
    if (pid == 0) {
        setenv("PORT",     std::to_string(g_endpoint_port).c_str(), 1);
        setenv("DB_PATH",  "/tmp/ut_e2e_backend.db", 1);
        setenv("API_KEY",  "e2e-key", 1);
        execlp("node", "node", "backend/server.js", (char*)nullptr);
        _exit(127);
    }
    unlink("/tmp/ut_e2e_backend.db");
    unlink("/tmp/ut_e2e_backend.db-shm");
    unlink("/tmp/ut_e2e_backend.db-wal");

    CHECK(wait_for_port(g_endpoint_port, 5000), "backend started");

    // ─── init SDK ─────────────────────────────────────────────────────────
    unlink("/tmp/ut_e2e_sdk.db");
    const char* cfg =
        "{\"db_path\":\"/tmp/ut_e2e_sdk.db\","
        "\"batch_size\":5,\"flush_interval_ms\":200,\"sampling_rate\":1.0}";
    ut_context* ctx = ut_init("e2e-key", cfg, UT_PLATFORM_IOS);
    CHECK(ctx != nullptr, "ut_init");
    ut_set_http_transport(ctx, sdk_http_cb, nullptr);

    ut_set_screen(ctx, "Home");
    ut_track(ctx, "button_clicked", "{\"label\":\"checkout\"}");
    ut_log_tap(ctx, "buy_btn", "Home", "{}");
    ut_log_network(ctx, "https://api.example.com/x", "GET", 200, 50, 0, 100, "");
    ut_log_json_error(ctx, "User", "missing field", "stack", "{...}");
    ut_log_memory_warning(ctx, 100*1024*1024, 512*1024*1024, "Home");
    ut_flush(ctx);

    // Wait up to 3s for events to land.
    int total = 0;
    for (int i = 0; i < 60; ++i) {
        total = backend_total();
        if (total >= 6) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    CHECK(total >= 6, "backend received >= 6 events (screen + 5 tracked)");

    ut_shutdown(ctx);

    // ─── persistence across restart ───────────────────────────────────────
    // Verify offline behaviour: tear down server, track, restart, verify flush.
    kill(pid, SIGTERM);
    waitpid(pid, nullptr, 0);
    // Re-open SDK (with the server down).
    ctx = ut_init("e2e-key", cfg, UT_PLATFORM_IOS);
    ut_set_http_transport(ctx, sdk_http_cb, nullptr);
    for (int i = 0; i < 3; ++i) {
        ut_track(ctx, "offline_event",
                 ("{\"i\":" + std::to_string(i) + "}").c_str());
    }
    ut_flush(ctx);
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    // Server's down — events should be persisted in queue.

    // Bring server back.
    pid = fork();
    if (pid == 0) {
        setenv("PORT",    std::to_string(g_endpoint_port).c_str(), 1);
        setenv("DB_PATH", "/tmp/ut_e2e_backend.db", 1);
        setenv("API_KEY", "e2e-key", 1);
        execlp("node", "node", "backend/server.js", (char*)nullptr);
        _exit(127);
    }
    CHECK(wait_for_port(g_endpoint_port, 5000), "backend restarted");
    ut_flush(ctx);

    int total2 = 0;
    for (int i = 0; i < 60; ++i) {
        total2 = backend_total();
        if (total2 >= 9) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    CHECK(total2 >= 9, "offline events delivered after server restart");

    ut_shutdown(ctx);
    kill(pid, SIGTERM);
    waitpid(pid, nullptr, 0);
    unlink("/tmp/ut_e2e_sdk.db");
    unlink("/tmp/ut_e2e_sdk.db-shm");
    unlink("/tmp/ut_e2e_sdk.db-wal");
    unlink("/tmp/ut_e2e_backend.db");
    unlink("/tmp/ut_e2e_backend.db-shm");
    unlink("/tmp/ut_e2e_backend.db-wal");

    printf("\nResult: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
