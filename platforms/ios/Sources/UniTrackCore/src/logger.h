#pragma once

#include "../include/unitrack/unitrack.h"
#include <atomic>
#include <string>

namespace unitrack {

class Logger {
public:
    static Logger& instance();
    void set_level(ut_log_level lvl);
    void log(ut_log_level lvl, const char* tag, const std::string& msg);

private:
    Logger() : level_(UT_LOG_WARN) {}
    std::atomic<ut_log_level> level_;
};

#define UT_LOGE(tag, msg) ::unitrack::Logger::instance().log(UT_LOG_ERROR, tag, msg)
#define UT_LOGW(tag, msg) ::unitrack::Logger::instance().log(UT_LOG_WARN,  tag, msg)
#define UT_LOGI(tag, msg) ::unitrack::Logger::instance().log(UT_LOG_INFO,  tag, msg)
#define UT_LOGD(tag, msg) ::unitrack::Logger::instance().log(UT_LOG_DEBUG, tag, msg)

} // namespace unitrack
