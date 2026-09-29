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
  -- What the OpenAI calls cost, per UTC day (audio actually sent, including retries, and chat tokens).
  CREATE TABLE IF NOT EXISTS spend (
    day TEXT PRIMARY KEY,
    audio_seconds REAL NOT NULL DEFAULT 0,
    prompt_tokens INTEGER NOT NULL DEFAULT 0,
    completion_tokens INTEGER NOT NULL DEFAULT 0,
    usd REAL NOT NULL DEFAULT 0
  );
`);

// Google sign-in (added later; migrate older databases in place).
const cols = db.query<{ name: string }, []>("PRAGMA table_info(users)").all().map((c) => c.name);
if (!cols.includes("google_sub")) db.exec("ALTER TABLE users ADD COLUMN google_sub TEXT");
db.exec("CREATE UNIQUE INDEX IF NOT EXISTS users_google_sub ON users(google_sub)");

export type User = { id: number; email: string; password_hash: string };

export const today = () => new Date().toISOString().slice(0, 10);

/** Monday of the current UTC week, and the moment the next week starts. */
export function weekBounds(now = new Date()) {
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  const next = new Date(d); next.setUTCDate(d.getUTCDate() + 7);
  return { start: d.toISOString().slice(0, 10), resetsAt: next.toISOString().replace(".000Z", "Z") };
}

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
  usageSince: db.query<{ seconds: number | null }, [number, string]>("SELECT SUM(seconds) AS seconds FROM usage WHERE user_id = ? AND day >= ?"),
  globalUsage: db.query<{ seconds: number | null }, [string]>("SELECT SUM(seconds) AS seconds FROM usage WHERE day = ?"),
  userByGoogle: db.query<User, [string]>("SELECT id, email, password_hash FROM users WHERE google_sub = ?"),
  linkGoogle: db.query("UPDATE users SET google_sub = ? WHERE id = ?"),
  insertGoogleUser: db.query<{ id: number }, [string, string, number, string]>(
    "INSERT INTO users (email, password_hash, google_sub, created_at, created_ip) VALUES (?, '', ?, ?, ?) RETURNING id"),
  addUsage: db.query(`INSERT INTO usage (user_id, day, seconds, requests) VALUES (?, ?, ?, 1)
    ON CONFLICT(user_id, day) DO UPDATE SET seconds = seconds + excluded.seconds, requests = requests + 1`),
  addSpend: db.query(`INSERT INTO spend (day, audio_seconds, prompt_tokens, completion_tokens, usd) VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(day) DO UPDATE SET audio_seconds = audio_seconds + excluded.audio_seconds,
      prompt_tokens = prompt_tokens + excluded.prompt_tokens, completion_tokens = completion_tokens + excluded.completion_tokens,
      usd = usd + excluded.usd`),
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
  userSecondsSince: (userId: number, day: string) => q.usageSince.get(userId, day)?.seconds ?? 0,
  globalSeconds: (day = today()) => q.globalUsage.get(day)?.seconds ?? 0,
  add: (userId: number, seconds: number, day = today()) => q.addUsage.run(userId, day, seconds),
};

export const Spend = {
  audio(seconds: number) {
    q.addSpend.run(today(), seconds, 0, 0, (seconds / 60) * config.price.transcribePerMinute);
  },
  tokens(prompt: number, completion: number) {
    const usd = (prompt * config.price.chatInputPerM + completion * config.price.chatOutputPerM) / 1e6;
    q.addSpend.run(today(), 0, prompt, completion, usd);
  },
};

/** Numbers for the admin dashboard. Days before spend tracking existed are estimated from billed minutes. */
export function stats(days = 30) {
  const since = new Date(Date.now() - (days - 1) * 86400_000).toISOString().slice(0, 10);
  const usage = db.query<{ day: string; seconds: number; requests: number; users: number }, [string]>(
    "SELECT day, SUM(seconds) AS seconds, SUM(requests) AS requests, COUNT(*) AS users FROM usage WHERE day >= ? GROUP BY day").all(since);
  const spend = db.query<{ day: string; audio_seconds: number; prompt_tokens: number; completion_tokens: number; usd: number }, [string]>(
    "SELECT * FROM spend WHERE day >= ?").all(since);
  const signups = db.query<{ day: string; n: number }, [number]>(
    "SELECT strftime('%Y-%m-%d', created_at / 1000, 'unixepoch') AS day, COUNT(*) AS n FROM users WHERE created_at >= ? GROUP BY day").all(Date.parse(since));
  const byDay = new Map<string, any>();
  for (let i = 0; i < days; i++) {
    const day = new Date(Date.parse(since) + i * 86400_000).toISOString().slice(0, 10);
    byDay.set(day, { day, usd: 0, minutes: 0, requests: 0, activeUsers: 0, signups: 0, estimated: false });
  }
  for (const u of usage) Object.assign(byDay.get(u.day) ?? {}, { minutes: u.seconds / 60, requests: u.requests, activeUsers: u.users });
  for (const s of signups) if (byDay.has(s.day)) byDay.get(s.day).signups = s.n;
  const tracked = new Map(spend.map((s) => [s.day, s]));
  // About 1,200 input and 250 output tokens of cleanup per request, for days with no spend rows.
  const chatPerRequest = (1200 * config.price.chatInputPerM + 250 * config.price.chatOutputPerM) / 1e6;
  for (const d of byDay.values()) {
    const s = tracked.get(d.day);
    if (s) d.usd = s.usd;
    else if (d.minutes > 0) { d.usd = d.minutes * config.price.transcribePerMinute + d.requests * chatPerRequest; d.estimated = true; }
  }
  const list = [...byDay.values()];
  const sum = (xs: any[]) => ({
    usd: xs.reduce((n, d) => n + d.usd, 0), minutes: xs.reduce((n, d) => n + d.minutes, 0),
    requests: xs.reduce((n, d) => n + d.requests, 0),
  });
  const week = weekBounds().start, month = today().slice(0, 8) + "01";
  const top = db.query<{ email: string; seconds: number; requests: number }, [string]>(
    "SELECT u.email, SUM(g.seconds) AS seconds, SUM(g.requests) AS requests FROM usage g JOIN users u ON u.id = g.user_id WHERE g.day >= ? GROUP BY u.id ORDER BY seconds DESC LIMIT 10").all(week);
  const totalUsers = db.query<{ n: number }, []>("SELECT COUNT(*) AS n FROM users").get()!.n;
  return {
    today: sum(list.filter((d) => d.day === today())),
    week: sum(list.filter((d) => d.day >= week)),
    month: sum(list.filter((d) => d.day >= month)),
    last30: sum(list),
    days: list,
    topUsersThisWeek: top.map((t) => ({ email: t.email, minutes: t.seconds / 60, requests: t.requests })),
    totalUsers,
    limits: { freeWeeklyMinutes: config.freeWeeklySeconds / 60, freeDailyMinutes: config.freeDailySeconds / 60, globalDailyMinutes: config.globalDailySeconds / 60 },
    prices: config.price,
  };
}
