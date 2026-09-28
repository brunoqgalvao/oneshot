import { config } from "./config";
import { Sessions, Usage, Users, today, type User } from "./db";
import { allow } from "./limits";
import { chat, transcribe, UpstreamError } from "./openai";
import { commandSystem, commandUser, dictationSystem, dictationUser, looksLikeDrift, strip } from "./prompts";

if (!config.openaiKey) {
  console.error("OPENAI_API_KEY is required");
  process.exit(1);
}

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });
const fail = (status: number, error: string, message: string) => json({ error, message }, status);

const sha256 = (s: string) => new Bun.CryptoHasher("sha256").update(s).digest("hex");
const newToken = () => "mur_" + Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64url");
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

function clientIP(req: Request, server: Bun.Server) {
  return req.headers.get("fly-client-ip") ?? req.headers.get("x-forwarded-for")?.split(",")[0].trim()
    ?? server.requestIP(req)?.address ?? "unknown";
}

function usageOf(user: User) {
  return { usedSeconds: Math.round(Usage.userSeconds(user.id)), limitSeconds: config.freeDailySeconds, resetsAt: `${today()}T24:00:00Z` };
}

function authed(req: Request) {
  const h = req.headers.get("authorization") ?? "";
  const token = h.startsWith("Bearer ") ? h.slice(7).trim() : "";
  if (!token) return null;
  const hash = sha256(token);
  const user = Sessions.user(hash);
  return user ? { user, hash } : null;
}

function startSession(user: { id: number; email: string }) {
  const token = newToken();
  Sessions.create(user.id, sha256(token));
  return token;
}

async function readCredentials(req: Request) {
  const body = (await req.json().catch(() => ({}))) as { email?: string; password?: string };
  return { email: String(body.email ?? "").trim().toLowerCase(), password: String(body.password ?? "") };
}

async function signup(req: Request, ip: string) {
  if (!allow(`signup:${ip}`, 5, 3_600_000)) return fail(429, "rate_limited", "Too many sign-ups from this network. Try again in an hour.");
  const { email, password } = await readCredentials(req);
  if (!EMAIL.test(email) || email.length > 200) return fail(400, "invalid_email", "Enter a valid email address.");
  if (password.length < 8 || password.length > 200) return fail(400, "weak_password", "Use a password with at least 8 characters.");
  if (Users.byEmail(email)) return fail(409, "email_taken", "An account with this email already exists. Sign in instead.");
  const id = Users.create(email, await Bun.password.hash(password), ip);
  const user = { id, email, password_hash: "" };
  return json({ token: startSession(user), email, usage: usageOf(user) }, 201);
}

async function login(req: Request, ip: string) {
  const { email, password } = await readCredentials(req);
  if (!allow(`login-ip:${ip}`, 20, 600_000) || !allow(`login-email:${email}`, 10, 600_000)) {
    return fail(429, "rate_limited", "Too many attempts. Wait a few minutes and try again.");
  }
  const user = Users.byEmail(email);
  const ok = user ? await Bun.password.verify(password, user.password_hash) : (await Bun.password.hash(password), false);
  if (!user || !ok) return fail(401, "invalid_credentials", "Wrong email or password.");
  return json({ token: startSession(user), email: user.email, usage: usageOf(user) });
}

type DictateMeta = {
  mode?: "dictate" | "command";
  durationSeconds?: number;
  language?: string;
  vocabulary?: string[];
  destination?: string;
  appName?: string;
  contextBefore?: string;
  selection?: string;
  cleanup?: boolean;
};

async function dictate(req: Request, user: User) {
  if (!allow(`dictate:${user.id}`, 30, 60_000)) return fail(429, "rate_limited", "Slow down a little — too many dictations this minute.");
  const form = await req.formData().catch(() => null);
  const audio = form?.get("audio");
  if (!(audio instanceof File)) return fail(400, "no_audio", "Missing audio.");
  if (audio.size > config.maxAudioBytes) return fail(413, "too_long", "That recording is too long.");
  let meta: DictateMeta = {};
  try { meta = JSON.parse(String(form?.get("meta") ?? "{}")); } catch {}

  // Bill at least what the file size implies (AAC at ~6 KB/s), so the client can't under-report.
  const seconds = Math.min(config.maxAudioSeconds, Math.max(Number(meta.durationSeconds) || 0, audio.size / 8000, 0.5));
  if (seconds >= config.maxAudioSeconds) return fail(413, "too_long", "Recordings are limited to 5 minutes.");
  const used = Usage.userSeconds(user.id);
  if (used + seconds > config.freeDailySeconds) {
    return json({ error: "daily_limit", message: `You've used today's free ${Math.round(config.freeDailySeconds / 60)} minutes. It resets at midnight UTC.`, usage: usageOf(user) }, 429);
  }
  if (Usage.globalSeconds() + seconds > config.globalDailySeconds) {
    return fail(503, "at_capacity", "Murmur's free tier is at capacity for today. Try again tomorrow.");
  }

  const vocabulary = (meta.vocabulary ?? []).map(String).slice(0, 100);
  const t0 = performance.now();
  const raw = (await transcribe(audio, {
    prompt: vocabulary.length ? "Vocabulary: " + vocabulary.join(", ") : undefined,
    language: meta.language,
  })).trim();
  const t1 = performance.now();
  Usage.add(user.id, seconds);

  let text = raw;
  const mode = meta.mode === "command" ? "command" : "dictate";
  if (raw && mode === "command") {
    text = strip(await chat(config.commandModel, commandSystem, commandUser({
      instruction: raw, selection: meta.selection?.slice(0, 20_000), destination: meta.destination, appName: meta.appName,
    }), 4000));
  } else if (raw && meta.cleanup !== false) {
    try {
      const cleaned = strip(await chat(config.cleanupModel, dictationSystem, dictationUser({
        raw, destination: meta.destination, appName: meta.appName,
        contextBefore: meta.contextBefore?.slice(-600), vocabulary,
      })));
      if (cleaned && !looksLikeDrift(raw, cleaned)) text = cleaned;
    } catch (e) {
      console.warn("cleanup failed, returning raw transcript:", (e as Error).message);
    }
  }
  const t2 = performance.now();
  return json({
    raw, text, mode,
    usage: usageOf(user),
    timings: { transcribeMs: Math.round(t1 - t0), cleanupMs: Math.round(t2 - t1) },
  });
}

const landing = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Murmur</title><style>body{font:16px/1.5 -apple-system,system-ui,sans-serif;max-width:560px;margin:15vh auto;padding:0 24px;color:#1d1b2e}
h1{font-size:34px;margin:0 0 4px}p{color:#5b5870}code{background:#f1effa;padding:2px 6px;border-radius:5px}</style></head>
<body><h1>Murmur</h1><p>Talk instead of type, in any Mac app. Hold <code>fn</code>, speak, release.</p>
<p>This is the Murmur server. Sign in from the Murmur app to get a free account.</p></body></html>`;

const server = Bun.serve({
  port: config.port,
  maxRequestBodySize: config.maxAudioBytes + 64 * 1024,
  async fetch(req, server) {
    const url = new URL(req.url);
    const ip = clientIP(req, server);
    const route = `${req.method} ${url.pathname}`;
    try {
      switch (route) {
        case "GET /": return new Response(landing, { headers: { "Content-Type": "text/html; charset=utf-8" } });
        case "GET /health": return json({ ok: true });
        case "POST /v1/auth/signup": return await signup(req, ip);
        case "POST /v1/auth/login": return await login(req, ip);
      }
      const auth = authed(req);
      if (!auth) return fail(401, "unauthorized", "Please sign in again.");
      switch (route) {
        case "GET /v1/me": return json({ email: auth.user.email, usage: usageOf(auth.user) });
        case "POST /v1/auth/logout": Sessions.delete(auth.hash); return json({ ok: true });
        case "POST /v1/dictate": return await dictate(req, auth.user);
      }
      return fail(404, "not_found", "Not found.");
    } catch (e) {
      if (e instanceof UpstreamError) {
        console.error("openai error", e.status, e.message);
        return fail(502, "upstream", e.status === 429 ? "The speech service is busy. Try again in a moment." : "The speech service failed. Try again.");
      }
      console.error(e);
      return fail(500, "server_error", "Something went wrong on the server.");
    }
  },
});

console.log(`Murmur server listening on :${server.port}`);
