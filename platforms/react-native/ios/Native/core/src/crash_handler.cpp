#include "crash_handler.h"
#include "logger.h"
#include "util.h"

#include <atomic>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

// Android's bionic defines __linux__ but ships no <execinfo.h>/backtrace(3),
// so exclude it here (the #if frames block is skipped on Android).
#if (defined(__APPLE__) || defined(__linux__)) && !defined(__ANDROID__)
  #include <execinfo.h>
  #define UT_HAVE_BACKTRACE 1
#endif

namespace unitrack {

std::atomic<bool> CrashHandler::installed_{false};
std::string       CrashHandler::crash_dir_;

// Signals we trap. SIGTRAP is included because Swift runtime traps — array
// index out of bounds, force-unwrap of nil, fatalError(), precondition failures
// — terminate the process via SIGTRAP / __builtin_trap rather than SIGSEGV, so
// without it those (very common) crashes would go uncaptured.
static const int kFatalSignals[] = {
    SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP
};

// Buffer reused by the signal handler — pre-allocated so we never
// touch the heap inside the handler.
static char         g_path_buf[1024];
static struct sigaction g_prev[ NSIG ];

// Async-signal-safe integer-to-string.
static int safe_itoa(long v, char* buf, int cap) {
    if (cap <= 0) return 0;
    if (v == 0) { buf[0] = '0'; return 1; }
    char tmp[32]; int n = 0;
    bool neg = v < 0; if (neg) v = -v;
    while (v && n < (int)sizeof(tmp)) { tmp[n++] = '0' + (v % 10); v /= 10; }
    int i = 0;
    if (neg && i < cap) buf[i++] = '-';
    while (n-- > 0 && i < cap) buf[i++] = tmp[n];
    return i;
}

// Write a NUL-terminated string to fd. Returns bytes written.
static ssize_t safe_write(int fd, const char* s) {
    return write(fd, s, strlen(s));
}

static void handle_signal(int sig, siginfo_t* info, void* /*uctx*/) {
    // Build path: <prefix>crash-pending.json. The prefix was cached as
    // a plain C string at install() time so we can read it safely here.
    extern const char* ut_crash_path_prefix;
    snprintf(g_path_buf, sizeof(g_path_buf),
             "%scrash-pending.json", ut_crash_path_prefix);

    int fd = open(g_path_buf, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        // Best effort — restore prev handler and re-raise.
        sigaction(sig, &g_prev[sig], nullptr);
        raise(sig);
        return;
    }

    // Build JSON manually with safe primitives only.
    safe_write(fd, "{\"signal\":");
    char num[32]; int n = safe_itoa(sig, num, sizeof(num));
    write(fd, num, n);
    safe_write(fd, ",\"signal_name\":\"");
    const char* name = "UNKNOWN";
    switch (sig) {
        case SIGSEGV: name = "SIGSEGV"; break;
        case SIGABRT: name = "SIGABRT"; break;
        case SIGBUS:  name = "SIGBUS";  break;
        case SIGFPE:  name = "SIGFPE";  break;
        case SIGILL:  name = "SIGILL";  break;
        case SIGTRAP: name = "SIGTRAP"; break;
    }
    safe_write(fd, name);
    safe_write(fd, "\",\"si_code\":");
    n = safe_itoa(info ? info->si_code : 0, num, sizeof(num)); write(fd, num, n);
    safe_write(fd, ",\"fault_addr\":");
    n = safe_itoa((long)(info ? (uintptr_t)info->si_addr : 0), num, sizeof(num));
    write(fd, num, n);

    // Stack trace via backtrace(3). The function reads call frames into
    // a fixed-size buffer; the symbol lookup happens later in the host
    // process on the next launch — we just write addresses now.
#if UT_HAVE_BACKTRACE
    safe_write(fd, ",\"frames\":[");
    void* frames[64];
    int   nf = backtrace(frames, 64);
    for (int i = 0; i < nf; ++i) {
        if (i > 0) safe_write(fd, ",");
        n = snprintf(num, sizeof(num), "\"%p\"", frames[i]);
        write(fd, num, n);
    }
    safe_write(fd, "]");
#endif
    safe_write(fd, "}\n");
    fsync(fd);
    close(fd);

    // Restore original handler and re-raise — let the OS crash for real.
    sigaction(sig, &g_prev[sig], nullptr);
    raise(sig);
}

// Cached path prefix used by the signal handler (must be a plain C
// pointer — std::string operations aren't async-signal-safe).
const char* ut_crash_path_prefix = "";

void CrashHandler::install(const std::string& crash_dir) {
    if (installed_.exchange(true)) return;
    crash_dir_ = crash_dir;
    if (!crash_dir_.empty() && crash_dir_.back() != '/') crash_dir_ += "/";

    // Persist into a static C buffer so the signal handler can read it.
    static char path_storage[1024];
    snprintf(path_storage, sizeof(path_storage), "%s", crash_dir_.c_str());
    ut_crash_path_prefix = path_storage;

    // Ensure directory exists.
    mkdir(crash_dir_.c_str(), 0700);

    struct sigaction sa{};
    sa.sa_sigaction = handle_signal;
    sa.sa_flags     = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);

    for (int s : kFatalSignals) {
        sigaction(s, &sa, &g_prev[s]);
    }
    UT_LOGI("CrashHandler", "installed in " + crash_dir_);
}

std::string CrashHandler::flush_pending_crash(const std::string& crash_dir) {
    std::string dir = crash_dir;
    if (!dir.empty() && dir.back() != '/') dir += "/";
    std::string path = dir + "crash-pending.json";

    FILE* fp = fopen(path.c_str(), "rb");
    if (!fp) return "";

    fseek(fp, 0, SEEK_END);
    long sz = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if (sz <= 0 || sz > 1024 * 1024) { fclose(fp); unlink(path.c_str()); return ""; }

    std::string buf(sz, '\0');
    size_t r = fread(&buf[0], 1, sz, fp);
    fclose(fp);
    unlink(path.c_str());
    buf.resize(r);
    return buf;
}

bool CrashHandler::is_installed() {
    return installed_.load();
}

} // namespace unitrack
