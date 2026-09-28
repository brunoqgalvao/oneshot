import { db } from "./db";

/**
 * Feedback from the app. Anyone can send it (signed in or not). Each install
 * has a random secret id, used to fetch the replies to its own feedback. An
 * automated loop (Claude Opus) reads new items through the admin routes,
 * ships what it can, and replies; the app then notifies the sender.
 */
db.exec(`
  CREATE TABLE IF NOT EXISTS feedback (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    install_id TEXT NOT NULL,
    user_id INTEGER,
    email TEXT,
    text TEXT NOT NULL,
    context TEXT,
    created_at INTEGER NOT NULL,
    status TEXT NOT NULL DEFAULT 'new',
    reply TEXT,
    replied_at INTEGER,
    seen_at INTEGER
  );
  CREATE INDEX IF NOT EXISTS feedback_install ON feedback(install_id);
  CREATE INDEX IF NOT EXISTS feedback_status ON feedback(status);
`);

export const STATUSES = ["new", "working", "shipped", "answered", "declined"] as const;
export type Status = (typeof STATUSES)[number];

export type FeedbackRow = {
  id: number; install_id: string; user_id: number | null; email: string | null; text: string; context: string | null;
  created_at: number; status: Status; reply: string | null; replied_at: number | null; seen_at: number | null;
};

const q = {
  insert: db.query<{ id: number }, [string, number | null, string | null, string, string | null, number]>(
    "INSERT INTO feedback (install_id, user_id, email, text, context, created_at) VALUES (?, ?, ?, ?, ?, ?) RETURNING id"),
  mine: db.query<FeedbackRow, [string]>("SELECT * FROM feedback WHERE install_id = ? ORDER BY created_at DESC LIMIT 100"),
  seen: db.query("UPDATE feedback SET seen_at = ? WHERE install_id = ? AND replied_at IS NOT NULL AND seen_at IS NULL"),
  byStatus: db.query<FeedbackRow, [string]>("SELECT * FROM feedback WHERE status = ? ORDER BY created_at ASC LIMIT 200"),
  all: db.query<FeedbackRow, []>("SELECT * FROM feedback ORDER BY created_at DESC LIMIT 200"),
  get: db.query<FeedbackRow, [number]>("SELECT * FROM feedback WHERE id = ?"),
  update: db.query("UPDATE feedback SET status = ?, reply = COALESCE(?, reply), replied_at = CASE WHEN ? IS NULL THEN replied_at ELSE ? END, seen_at = CASE WHEN ? IS NULL THEN seen_at ELSE NULL END WHERE id = ?"),
};

export const Feedback = {
  create: (installId: string, userId: number | null, email: string | null, text: string, context: string | null) =>
    q.insert.get(installId, userId, email, text, context, Date.now())!.id,
  mine: (installId: string) => q.mine.all(installId),
  markSeen: (installId: string) => q.seen.run(Date.now(), installId),
  list: (status?: string) => (status && status !== "all" ? q.byStatus.all(status) : q.all.all()),
  get: (id: number) => q.get.get(id),
  /** A reply resets seen_at so the sender gets notified. */
  update(id: number, status: Status, reply: string | null) {
    const now = reply ? Date.now() : null;
    q.update.run(status, reply, reply, now, reply, id);
    return q.get.get(id);
  },
};

/** What the sender sees: no install id, no internal context. */
export const publicView = (f: FeedbackRow) => ({
  id: f.id, text: f.text, status: f.status, reply: f.reply, createdAt: f.created_at, repliedAt: f.replied_at, seen: f.seen_at != null,
});
