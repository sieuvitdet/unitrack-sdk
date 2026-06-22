#pragma once

#include "../include/unitrack/unitrack.h"
#include <atomic>
#include <string>

namespace unitrack {

// Installs POSIX signal handlers (SIGSEGV, SIGABRT, SIGBUS, SIGFPE,
// SIGILL, SIGPIPE) and a std::terminate handler. On a fatal signal,
// captures a minimal stack trace, writes it to a crash file on disk,
// and re-raises the signal so the OS continues its normal abort.
//
// On the next app launch, CrashHandler::flush_pending_crash() picks up
// the file and emits it through the SDK before deleting it.
//
// This handler is intentionally minimal: signal handlers must be
// async-signal-safe. We only use write(2), backtrace(3), and
// snprintf-into-stack-buffer.
class CrashHandler {
public:
    // Install handlers. crash_dir is where pending crash files are
    // written (usually app's documents/cache directory).
    static void install(const std::string& crash_dir);

    // Read any pending crash file from disk and forward to the tracker.
    // Returns the crash JSON if present (caller emits it), empty string
    // otherwise. Deletes the file after reading.
    static std::string flush_pending_crash(const std::string& crash_dir);

    static bool is_installed();

private:
    static std::atomic<bool> installed_;
    static std::string       crash_dir_;
};

} // namespace unitrack
