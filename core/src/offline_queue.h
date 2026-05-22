#pragma once

#include "event.h"
#include <memory>
#include <mutex>
#include <string>
#include <vector>

struct sqlite3;

namespace unitrack {

// Persistent FIFO queue backed by SQLite. Thread-safe.
//
// Schema: events(id INTEGER PRIMARY KEY AUTOINCREMENT,
//                event_id TEXT UNIQUE,
//                created_at INTEGER,
//                payload TEXT,
//                retry_count INTEGER DEFAULT 0)
//
// Operations are designed to be cheap on the hot path (enqueue) and
// batched on the background flush path (dequeue/remove).
class OfflineQueue {
public:
    explicit OfflineQueue(const std::string& db_path);
    ~OfflineQueue();

    // Disallow copy.
    OfflineQueue(const OfflineQueue&) = delete;
    OfflineQueue& operator=(const OfflineQueue&) = delete;

    // Enqueue one event. Returns true on success.
    bool enqueue(const Event& e);

    // Dequeue up to `max` oldest events. Returns the events and their
    // row ids so they can be removed after a successful upload.
    struct DequeuedEvent {
        int64_t     row_id;
        Event       event;
        int         retry_count;
    };
    std::vector<DequeuedEvent> peek(int max);

    // Remove events by row_id after successful upload.
    void remove(const std::vector<int64_t>& row_ids);

    // Increment retry count for events still in flight.
    void mark_retry(const std::vector<int64_t>& row_ids);

    // Trim queue: enforce max size & max age.
    void trim(int max_size, int max_age_days);

    // Total event count currently in queue.
    int count();

private:
    sqlite3*    db_ = nullptr;
    std::mutex  mu_;

    bool open(const std::string& db_path);
    bool ensure_schema();
};

} // namespace unitrack
