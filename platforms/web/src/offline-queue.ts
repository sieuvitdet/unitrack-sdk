// IndexedDB-backed offline queue. Provider POST fail → retain event; reload
// page hoặc reconnect online → tự flush.
//
// Tương đương SQLite queue ở C++ core. Tradeoff: IndexedDB async-only (vs
// SQLite sync trong core C++) → flush + persist phải qua Promise chain.

import type { QueuedEvent } from './types';

const DB_NAME = 'unitrack';
const STORE = 'events';
const DB_VERSION = 1;

/** Trần queue — cùng tinh thần `maxLocalStorageQueueSize` của Snowplow (1000)
 * và trần 10k của C++ core. Vượt trần thì bỏ event CŨ nhất: khi mạng hỏng lâu,
 * event gần đây phản ánh phiên hiện tại tốt hơn event từ hôm kia. */
export const MAX_QUEUE = 1000;

let dbPromise: Promise<IDBDatabase> | null = null;

function openDB(): Promise<IDBDatabase> {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    if (typeof indexedDB === 'undefined') {
      reject(new Error('IndexedDB unavailable'));
      return;
    }
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        db.createObjectStore(STORE, { keyPath: 'id', autoIncrement: true });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

export async function enqueue(event: QueuedEvent): Promise<void> {
  try {
    const db = await openDB();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE, 'readwrite');
      tx.objectStore(STORE).add(event);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  } catch { /* IndexedDB unavailable → event lost. Trade-off chấp nhận: vs
               crash page khi private mode + ko có IndexedDB. */ }
}

/** Ghi cả batch trong MỘT transaction rồi cắt bớt nếu vượt trần.
 * Dùng khi POST hỏng — giữ event qua reload/đóng tab. */
export async function enqueueBatch(events: QueuedEvent[]): Promise<void> {
  if (!events.length) return;
  try {
    const db = await openDB();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE, 'readwrite');
      const store = tx.objectStore(STORE);
      for (const ev of events) store.add(ev);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
    await trimToCap();
  } catch { /* IndexedDB không dùng được (private mode) → chấp nhận mất, còn hơn crash */ }
}

/** Giữ queue trong trần: xoá từ đầu (key tăng dần = cũ nhất trước). */
async function trimToCap(): Promise<void> {
  try {
    const db = await openDB();
    const n = await pendingCount();
    if (n <= MAX_QUEUE) return;
    let toDelete = n - MAX_QUEUE;
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE, 'readwrite');
      const req = tx.objectStore(STORE).openCursor();
      req.onsuccess = () => {
        const cur = req.result;
        if (!cur || toDelete <= 0) return;
        cur.delete();
        toDelete--;
        cur.continue();
      };
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  } catch { /* ignore */ }
}

export async function drain(): Promise<QueuedEvent[]> {
  try {
    const db = await openDB();
    return new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, 'readonly');
      const req = tx.objectStore(STORE).getAll();
      req.onsuccess = () => resolve(req.result as QueuedEvent[]);
      req.onerror = () => reject(req.error);
    });
  } catch {
    return [];
  }
}

export async function removeIds(ids: number[]): Promise<void> {
  if (!ids.length) return;
  try {
    const db = await openDB();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE, 'readwrite');
      const store = tx.objectStore(STORE);
      ids.forEach((id) => store.delete(id));
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
  } catch { /* ignore */ }
}

export async function pendingCount(): Promise<number> {
  try {
    const db = await openDB();
    return new Promise((resolve) => {
      const tx = db.transaction(STORE, 'readonly');
      const req = tx.objectStore(STORE).count();
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => resolve(0);
    });
  } catch {
    return 0;
  }
}
