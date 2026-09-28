import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { config } from "./config";

mkdirSync(dirname(config.databasePath), { recursive: true });
export const db = new Database(config.databasePath, { create: true });
db.exec("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;");
db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    created_ip TEXT
  );
  CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS usage (
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day TEXT NOT NULL,
    seconds REAL NOT NULL DEFAULT 0,
    requests INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, day)
  );
`);

// Google sign-in (added later; migrate older databases in place).
const cols = db.query<{ name: string }, []>("PRAGMA table_info(users)").all().map((c) => c.name);
if (!cols.includes("google_sub")) db.exec("ALTER TABLE users ADD COLUMN google_sub TEXT");
db.exec("CREATE UNIQUE INDEX IF NOT EXISTS users_google_sub ON users(google_sub)");

export type User = { id: number; email: string; password_hash: string };

export const today = () => new Date().toISOString().slice(0, 10);

const q = {
  userByEmail: db.query<User, [string]>("SELECT id, email, password_hash FROM users WHERE email = ?"),
  insertUser: db.query<{ id: number }, [string, string, number, string]>(
    "INSERT INTO users (email, password_hash, created_at, created_ip) VALUES (?, ?, ?, ?) RETURNING id"),
  insertSession: db.query("INSERT INTO sessions (token_hash, user_id, created_at, last_used_at) VALUES (?, ?, ?, ?)"),
  sessionUser: db.query<User, [string]>(
    "SELECT u.id, u.email, u.password_hash FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token_hash = ?"),
  touchSession: db.query("UPDATE sessions SET last_used_at = ? WHERE token_hash = ?"),
  deleteSession: db.query("DELETE FROM sessions WHERE token_hash = ?"),
  usage: db.query<{ seconds: number }, [number, string]>("SELECT seconds FROM usage WHERE user_id = ? AND day = ?"),
  globalUsage: db.query<{ seconds: number | null }, [string]>("SELECT SUM(seconds) AS seconds FROM usage WHERE day = ?"),
  userByGoogle: db.query<User, [string]>("SELECT id, email, password_hash FROM users WHERE google_sub = ?"),
  linkGoogle: db.query("UPDATE users SET google_sub = ? WHERE id = ?"),
  insertGoogleUser: db.query<{ id: number }, [string, string, number, string]>(
    "INSERT INTO users (email, password_hash, google_sub, created_at, created_ip) VALUES (?, '', ?, ?, ?) RETURNING id"),
  addUsage: db.query(`INSERT INTO usage (user_id, day, seconds, requests) VALUES (?, ?, ?, 1)
    ON CONFLICT(user_id, day) DO UPDATE SET seconds = seconds + excluded.seconds, requests = requests + 1`),
};

export const Users = {
  byEmail: (email: string) => q.userByEmail.get(email),
  create: (email: string, hash: string, ip: string) => q.insertUser.get(email, hash, Date.now(), ip)!.id,
  /** Finds the Google user, links an existing email account, or creates one. */
  fromGoogle(sub: string, email: string, ip: string): User {
    const bySub = q.userByGoogle.get(sub);
    if (bySub) return bySub;
    const byEmail = q.userByEmail.get(email);
    if (byEmail) { q.linkGoogle.run(sub, byEmail.id); return byEmail; }
    const id = q.insertGoogleUser.get(email, sub, Date.now(), ip)!.id;
    return { id, email, password_hash: "" };
  },
};

export const Sessions = {
  create(userId: number, tokenHash: string) {
    const now = Date.now();
    q.insertSession.run(tokenHash, userId, now, now);
  },
  user(tokenHash: string) {
    const u = q.sessionUser.get(tokenHash);
    if (u) q.touchSession.run(Date.now(), tokenHash);
    return u;
  },
  delete: (tokenHash: string) => q.deleteSession.run(tokenHash),
};

export const Usage = {
  userSeconds: (userId: number, day = today()) => q.usage.get(userId, day)?.seconds ?? 0,
  globalSeconds: (day = today()) => q.globalUsage.get(day)?.seconds ?? 0,
  add: (userId: number, seconds: number, day = today()) => q.addUsage.run(userId, day, seconds),
};
