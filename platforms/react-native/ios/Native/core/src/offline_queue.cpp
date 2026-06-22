#include "offline_queue.h"
#include "logger.h"
#include "util.h"
#include <sqlite3.h>
#include <cstring>
#include <cstdlib>
#include <cstdio>

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
    // 1) Create the table (new installs get next_retry_at directly) + the index
    //    that only references columns guaranteed to exist on ALL versions.
    //    IMPORTANT: do NOT create the next_retry_at index here — on a pre-backoff
    //    database the column doesn't exist yet, so that index would fail and abort
    //    the whole exec before the migration below runs.
    const char* sql =
        "CREATE TABLE IF NOT EXISTS events ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  event_id TEXT UNIQUE NOT NULL,"
        "  created_at INTEGER NOT NULL,"
        "  payload TEXT NOT NULL,"
        "  retry_count INTEGER NOT NULL DEFAULT 0,"
        "  next_retry_at INTEGER NOT NULL DEFAULT 0"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_events_created_at ON events(created_at);";
    char* err = nullptr;
    int rc = sqlite3_exec(db_, sql, nullptr, nullptr, &err);
    if (rc != SQLITE_OK) {
        UT_LOGE("OfflineQueue", std::string("schema creation failed: ") + (err ? err : ""));
        if (err) sqlite3_free(err);
        return false;
    }

    // 2) Migrate a pre-backoff database (events table created before
    //    next_retry_at existed). Add the column if missing.
    bool has_col = false;
    sqlite3_stmt* st = nullptr;
    if (sqlite3_prepare_v2(db_, "PRAGMA table_info(events);", -1, &st, nullptr) == SQLITE_OK) {
        while (sqlite3_step(st) == SQLITE_ROW) {
            const unsigned char* name = sqlite3_column_text(st, 1);
            if (name && std::strcmp(reinterpret_cast<const char*>(name), "next_retry_at") == 0) {
                has_col = true;
                break;
            }
        }
        sqlite3_finalize(st);
    }
    if (!has_col) {
        sqlite3_exec(db_,
            "ALTER TABLE events ADD COLUMN next_retry_at INTEGER NOT NULL DEFAULT 0;",
            nullptr, nullptr, nullptr);
    }

    // 3) Now the column is guaranteed to exist — create its index.
    sqlite3_exec(db_,
        "CREATE INDEX IF NOT EXISTS idx_events_next_retry ON events(next_retry_at);",
        nullptr, nullptr, nullptr);
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

    // Only events whose backoff gate has passed are due. New events have
    // next_retry_at = 0, so they are sent immediately; failed events wait until
    // their scheduled retry time. Still FIFO among due events.
    const char* sql =
        "SELECT id, event_id, created_at, payload, retry_count "
        "FROM events WHERE next_retry_at <= ? ORDER BY id ASC LIMIT ?;";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db_, sql, -1, &stmt, nullptr) != SQLITE_OK) return out;
    sqlite3_bind_int64(stmt, 1, current_time_ms());
    sqlite3_bind_int(stmt, 2, max);

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

void OfflineQueue::mark_retry(const std::vector<int64_t>& row_ids,
                             int retry_base_ms, int retry_max_ms) {
    if (row_ids.empty()) return;
    std::lock_guard<std::mutex> lock(mu_);
    if (!db_) return;

    const int64_t now = current_time_ms();
    if (retry_base_ms <= 0) retry_base_ms = 5000;
    if (retry_max_ms  <= 0) retry_max_ms  = 300000;

    // Increment retry_count, then schedule next_retry_at using the NEW count:
    //   delay = min(base * 2^(retry_count-1), max), plus up to 20% jitter, so a
    //   fleet of devices doesn't retry a recovering server in lockstep.
    sqlite3_exec(db_, "BEGIN;", nullptr, nullptr, nullptr);

    // Read current retry_count per row, then update count + next_retry_at.
    sqlite3_stmt* sel = nullptr;
    sqlite3_prepare_v2(db_, "SELECT retry_count FROM events WHERE id = ?;", -1, &sel, nullptr);
    sqlite3_stmt* upd = nullptr;
    sqlite3_prepare_v2(db_,
        "UPDATE events SET retry_count = ?, next_retry_at = ? WHERE id = ?;",
        -1, &upd, nullptr);

    for (auto id : row_ids) {
        int rc = 0;
        sqlite3_bind_int64(sel, 1, id);
        if (sqlite3_step(sel) == SQLITE_ROW) rc = sqlite3_column_int(sel, 0);
        sqlite3_reset(sel);

        int new_count = rc + 1;
        // Exponential delay, capped. Shift on a 64-bit value, guard the exponent
        // so it never overflows (cap kicks in well before that anyway).
        int shift = new_count - 1;
        if (shift > 30) shift = 30;
        int64_t delay = (int64_t)retry_base_ms * ((int64_t)1 << shift);
        if (delay > retry_max_ms) delay = retry_max_ms;
        // +0..20% jitter.
        int64_t jitter = (delay / 5 > 0) ? (int64_t)(std::rand() % (int)(delay / 5 + 1)) : 0;
        int64_t next = now + delay + jitter;

        sqlite3_bind_int  (upd, 1, new_count);
        sqlite3_bind_int64(upd, 2, next);
        sqlite3_bind_int64(upd, 3, id);
        sqlite3_step(upd);
        sqlite3_reset(upd);
    }
    sqlite3_finalize(sel);
    sqlite3_finalize(upd);
    sqlite3_exec(db_, "COMMIT;", nullptr, nullptr, nullptr);
}

void OfflineQueue::trim(int max_size, int max_age_days, int max_retries) {
    std::lock_guard<std::mutex> lock(mu_);
    if (!db_) return;

    int64_t cutoff = current_time_ms() - (int64_t)max_age_days * 86400LL * 1000LL;
    if (max_retries <= 0) max_retries = 10;

    // Delete events older than cutoff or that have exhausted their retries.
    sqlite3_stmt* stmt = nullptr;
    sqlite3_prepare_v2(db_,
        "DELETE FROM events WHERE created_at < ? OR retry_count > ?;",
        -1, &stmt, nullptr);
    sqlite3_bind_int64(stmt, 1, cutoff);
    sqlite3_bind_int  (stmt, 2, max_retries);
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

std::vector<std::pair<std::string, int>> OfflineQueue::counts_by_event_name() {
    std::vector<std::pair<std::string, int>> out;
    std::lock_guard<std::mutex> lock(mu_);
    if (!db_) return out;
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db_, "SELECT payload FROM events;", -1, &stmt, nullptr) != SQLITE_OK) {
        return out;
    }
    // Tally into a flat vector + linear scan — the queue is bounded by
    // max_queue_size (default 10k) so this is fine and avoids dragging in
    // <unordered_map> which already costs more on small N.
    auto bump = [&out](const std::string& name) {
        for (auto& p : out) {
            if (p.first == name) { p.second += 1; return; }
        }
        out.emplace_back(name, 1);
    };
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        const unsigned char* txt = sqlite3_column_text(stmt, 0);
        if (!txt) continue;
        // Payload shape (Event::to_json):
        //   {"event_id":"...","event_name":"<name>","timestamp":...,...}
        // event_name is always the 2nd key. Find by literal substring —
        // no JSON parser needed and immune to schema reordering since we
        // own to_json().
        std::string payload(reinterpret_cast<const char*>(txt));
        auto p = payload.find("\"event_name\":\"");
        if (p == std::string::npos) continue;
        p += 14;  // strlen(`"event_name":"`)
        auto q = payload.find('"', p);
        if (q == std::string::npos) continue;
        bump(payload.substr(p, q - p));
    }
    sqlite3_finalize(stmt);
    return out;
}

} // namespace unitrack
