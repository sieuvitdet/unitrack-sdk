#include "offline_queue.h"
#include "logger.h"
#include "util.h"
#include <sqlite3.h>
#include <cstring>

namespace unitrack {

OfflineQueue::OfflineQueue(const std::string& db_path) {
    if (!open(db_path) || !ensure_schema()) {
        UT_LOGE("OfflineQueue", "failed to initialize database at " + db_path);
    }
}

OfflineQueue::~OfflineQueue() {
    if (db_) {
        sqlite3_close(db_);
        db_ = nullptr;
    }
}

bool OfflineQueue::open(const std::string& db_path) {
    int rc = sqlite3_open(db_path.c_str(), &db_);
    if (rc != SQLITE_OK) {
        UT_LOGE("OfflineQueue", std::string("sqlite3_open failed: ") + sqlite3_errmsg(db_));
        return false;
    }
    // Enable WAL for concurrent reads during flush.
    char* err = nullptr;
    sqlite3_exec(db_, "PRAGMA journal_mode=WAL;", nullptr, nullptr, &err);
    if (err) sqlite3_free(err);
    sqlite3_exec(db_, "PRAGMA synchronous=NORMAL;", nullptr, nullptr, &err);
    if (err) sqlite3_free(err);
    return true;
}

bool OfflineQueue::ensure_schema() {
    const char* sql =
        "CREATE TABLE IF NOT EXISTS events ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  event_id TEXT UNIQUE NOT NULL,"
        "  created_at INTEGER NOT NULL,"
        "  payload TEXT NOT NULL,"
        "  retry_count INTEGER NOT NULL DEFAULT 0"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at);";
    char* err = nullptr;
    int rc = sqlite3_exec(db_, sql, nullptr, nullptr, &err);
    if (rc != SQLITE_OK) {
        UT_LOGE("OfflineQueue", std::string("schema creation failed: ") + (err ? err : ""));
        if (err) sqlite3_free(err);
        return false;
    }
    return true;
}

bool OfflineQueue::enqueue(const Event& e) {
    std::lock_guard<std::mutex> lock(mu_);
    if (!db_) return false;

    const char* sql = "INSERT OR IGNORE INTO events(event_id, created_at, payload) "
                      "VALUES(?, ?, ?);";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) {
        UT_LOGE("OfflineQueue", "prepare enqueue failed");
        return false;
    }
    std::string payload = e.to_json();
    sqlite3_bind_text (stmt, 1, e.event_id.c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 2, e.timestamp_ms);
    sqlite3_bind_text (stmt, 3, payload.c_str(),    -1, SQLITE_TRANSIENT);
    int rc = sqlite3_step(stmt);
    sqlite3_finalize(stmt);
    return rc == SQLITE_DONE;
}

std::vector<OfflineQueue::DequeuedEvent> OfflineQueue::peek(int max) {
    std::vector<DequeuedEvent> out;
    std::lock_guard<std::mutex> lock(mu_);
    if (!db_) return out;

    const char* sql =
        "SELECT id, event_id, created_at, payload, retry_count "
        "FROM events ORDER BY id ASC LIMIT ?;";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) return out;
    sqlite3_bind_int(stmt, 1, max);

    while (sqlite3_step(stmt) == SQLITE_ROW) {
        DequeuedEvent d;
        d.row_id            = sqlite3_column_int64(stmt, 0);
        d.event.event_id    = reinterpret_cast<const char*>(sqlite3_column_text(stmt, 1));
        d.event.timestamp_ms= sqlite3_column_int64(stmt, 2);
        const unsigned char* p = sqlite3_column_text(stmt, 3);
        // payload is the already-serialized event JSON
        d.event.properties_json = p ? reinterpret_cast<const char*>(p) : "";
        d.retry_count       = sqlite3_column_int(stmt, 4);
        out.push_back(std::move(d));
    }
    sqlite3_finalize(stmt);
    return out;
}

void OfflineQueue::remove(const std::vector<int64_t>& row_ids) {
    if (row_ids.empty()) return;
    std::lock_guard<std::mutex> lock(mu_);
    if (!db_) return;

    sqlite3_exec(db_, "BEGIN;", nullptr, nullptr, nullptr);
    const char* sql = "DELETE FROM events WHERE id = ?;";
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr);
    for (auto id : row_ids) {
        sqlite3_bind_int64(stmt, 1, id);
        sqlite3_step(stmt);
        sqlite3_reset(stmt);
    }
    sqlite3_finalize(stmt);
    sqlite3_exec(db_, "COMMIT;", nullptr, nullptr, nullptr);
}

void OfflineQueue::mark_retry(const std::vector<int64_t>& row_ids) {
    if (row_ids.empty()) return;
    std::lock_guard<std::mutex> lock(mu_);
    if (!db_) return;

    sqlite3_exec(db_, "BEGIN;", nullptr, nullptr, nullptr);
    const char* sql = "UPDATE events SET retry_count = retry_count + 1 WHERE id = ?;";
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr);
    for (auto id : row_ids) {
        sqlite3_bind_int64(stmt, 1, id);
        sqlite3_step(stmt);
        sqlite3_reset(stmt);
    }
    sqlite3_finalize(stmt);
    sqlite3_exec(db_, "COMMIT;", nullptr, nullptr, nullptr);
}

void OfflineQueue::trim(int max_size, int max_age_days) {
    std::lock_guard<std::mutex> lock(mu_);
    if (!db_) return;

    int64_t cutoff = current_time_ms() - (int64_t)max_age_days * 86400LL * 1000LL;
    sqlite3_stmt* stmt = nullptr;

    // Delete events older than cutoff or with retry_count > 10.
    sqlite3_prepare_v2(db_,
        "DELETE FROM events WHERE created_at < ? OR retry_count > 10;",
        -1, &stmt, nullptr);
    sqlite3_bind_int64(stmt, 1, cutoff);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);

    // Keep only the newest max_size rows.
    char buf[256];
    snprintf(buf, sizeof(buf),
        "DELETE FROM events WHERE id NOT IN "
        "(SELECT id FROM events ORDER BY id DESC LIMIT %d);", max_size);
    sqlite3_exec(db_, buf, nullptr, nullptr, nullptr);
}

int OfflineQueue::count() {
    std::lock_guard<std::mutex> lock(mu_);
    if (!db_) return 0;
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_, "SELECT COUNT(*) FROM events;", -1, &stmt, nullptr);
    int n = 0;
    if (sqlite3_step(stmt) == SQLITE_ROW) n = sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
    return n;
}

} // namespace unitrack
