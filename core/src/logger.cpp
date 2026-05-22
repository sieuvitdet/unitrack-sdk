#include "logger.h"
#include <cstdio>

#if defined(__ANDROID__)
  #include <android/log.h>
#endif

namespace unitrack {

Logger& Logger::instance() {
    static Logger inst;
    return inst;
}

void Logger::set_level(ut_log_level lvl) {
    level_.store(lvl);
}

void Logger::log(ut_log_level lvl, const char* tag, const std::string& msg) {
    if (lvl > level_.load()) return;

#if defined(__ANDROID__)
    int prio = ANDROID_LOG_DEBUG;
    switch (lvl) {
        case UT_LOG_ERROR: prio = ANDROID_LOG_ERROR; break;
        case UT_LOG_WARN:  prio = ANDROID_LOG_WARN;  break;
        case UT_LOG_INFO:  prio = ANDROID_LOG_INFO;  break;
        case UT_LOG_DEBUG: prio = ANDROID_LOG_DEBUG; break;
    }
    __android_log_print(prio, tag, "%s", msg.c_str());
#else
    const char* prefix = "?";
    switch (lvl) {
        case UT_LOG_ERROR: prefix = "E"; break;
        case UT_LOG_WARN:  prefix = "W"; break;
        case UT_LOG_INFO:  prefix = "I"; break;
        case UT_LOG_DEBUG: prefix = "D"; break;
    }
    fprintf(stderr, "[UniTrack/%s] %s: %s\n", prefix, tag, msg.c_str());
#endif
}

} // namespace unitrack
