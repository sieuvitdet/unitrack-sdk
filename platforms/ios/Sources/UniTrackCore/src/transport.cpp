#include "transport.h"
#include "logger.h"
#include <utility>

#if defined(UT_USE_LIBCURL)
  #include <curl/curl.h>
#endif

namespace unitrack {

Transport::Transport(std::string endpoint, std::string api_key, int timeout_ms)
    : endpoint_(std::move(endpoint)),
      api_key_(std::move(api_key)),
      timeout_ms_(timeout_ms) {}

void Transport::set_callback(ut_http_send_fn fn, void* user_data) {
    http_fn_   = fn;
    user_data_ = user_data;
}

bool Transport::send(const std::string& payload) {
    if (http_fn_) {
        std::string headers = "{\"Content-Type\":\"application/json\","
                              "\"Authorization\":\"Bearer " + api_key_ + "\"}";
        int status = http_fn_(endpoint_.c_str(), "POST",
                              headers.c_str(),
                              payload.c_str(), payload.size(),
                              user_data_);
        return status >= 200 && status < 300;
    }
    return send_builtin(payload);
}

#if defined(UT_USE_LIBCURL)

static size_t curl_discard(void*, size_t size, size_t nmemb, void*) {
    return size * nmemb;
}

bool Transport::send_builtin(const std::string& payload) {
    CURL* h = curl_easy_init();
    if (!h) return false;

    struct curl_slist* hdrs = nullptr;
    hdrs = curl_slist_append(hdrs, "Content-Type: application/json");
    std::string auth = "Authorization: Bearer " + api_key_;
    hdrs = curl_slist_append(hdrs, auth.c_str());

    curl_easy_setopt(h, CURLOPT_URL,             endpoint_.c_str());
    curl_easy_setopt(h, CURLOPT_POST,            1L);
    curl_easy_setopt(h, CURLOPT_POSTFIELDS,      payload.c_str());
    curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE,   (long)payload.size());
    curl_easy_setopt(h, CURLOPT_HTTPHEADER,      hdrs);
    curl_easy_setopt(h, CURLOPT_TIMEOUT_MS,      (long)timeout_ms_);
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION,   curl_discard);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL,        1L);

    CURLcode rc = curl_easy_perform(h);
    long status = 0;
    curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(hdrs);
    curl_easy_cleanup(h);

    if (rc != CURLE_OK) {
        UT_LOGW("Transport", std::string("curl failed: ") + curl_easy_strerror(rc));
        return false;
    }
    return status >= 200 && status < 300;
}

#else

bool Transport::send_builtin(const std::string& /*payload*/) {
    // Built without libcurl — platform binding MUST install an HTTP callback.
    UT_LOGE("Transport",
            "no HTTP callback installed and built without libcurl; events dropped");
    return false;
}

#endif

} // namespace unitrack
