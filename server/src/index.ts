import { config } from "./config";
import { Sessions, Usage, Users, today, type User } from "./db";
import { allow } from "./limits";
import { chat, transcribe, UpstreamError } from "./openai";
import * as google from "./google";
import { Feedback, publicView, STATUSES, type Status } from "./feedback";
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
  if (user && !user.password_hash) return fail(401, "use_google", "This account signs in with Google.");
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
    return fail(503, "at_capacity", "Oneshot's free tier is at capacity for today. Try again tomorrow.");
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

const PUBLIC = new URL("../public/", import.meta.url).pathname;
const staticFiles: Record<string, string> = {
  "/": "index.html", "/install.sh": "install.sh", "/demo.mp4": "demo.mp4", "/icon.png": "icon.png", "/og.png": "og.png",
};
const staticTypes: Record<string, string> = {
  html: "text/html; charset=utf-8", sh: "text/x-shellscript; charset=utf-8", mp4: "video/mp4", png: "image/png",
};
function serveStatic(pathname: string) {
  const name = staticFiles[pathname];
  if (!name) return null;
  const file = Bun.file(PUBLIC + name);
  return new Response(file, {
    headers: { "Content-Type": staticTypes[name.split(".").pop()!] ?? "application/octet-stream", "Cache-Control": "public, max-age=300" },
  });
}

const INSTALL = /^[A-Za-z0-9_-]{22,64}$/;

async function sendFeedback(req: Request, ip: string) {
  const installId = req.headers.get("x-install-id") ?? "";
  if (!INSTALL.test(installId)) return fail(400, "no_install", "Missing install id.");
  if (!allow(`feedback:${installId}`, 10, 3_600_000) || !allow(`feedback-ip:${ip}`, 30, 3_600_000)) {
    return fail(429, "rate_limited", "Thanks! That's a lot of feedback for one hour. Try again a bit later.");
  }
  const body = (await req.json().catch(() => ({}))) as { text?: string; context?: Record<string, unknown> };
  const text = String(body.text ?? "").trim();
  if (text.length < 2) return fail(400, "empty", "Write something first.");
  if (text.length > 5000) return fail(400, "too_long", "Keep it under 5,000 characters.");
  const user = authed(req)?.user ?? null;
  const context = body.context ? JSON.stringify(body.context).slice(0, 2000) : null;
  const id = Feedback.create(installId, user?.id ?? null, user?.email ?? null, text, context);
  console.log(`feedback #${id} received`);
  return json({ id }, 201);
}

function myFeedback(req: Request) {
  const installId = req.headers.get("x-install-id") ?? "";
  if (!INSTALL.test(installId)) return fail(400, "no_install", "Missing install id.");
  return json({ items: Feedback.mine(installId).map(publicView) });
}

function isAdmin(req: Request) {
  const h = req.headers.get("authorization") ?? "";
  return config.adminToken.length >= 32 && h === `Bearer ${config.adminToken}`;
}

async function adminFeedback(req: Request, url: URL) {
  if (!isAdmin(req)) return fail(401, "unauthorized", "Admin only.");
  if (req.method === "GET") return json({ items: Feedback.list(url.searchParams.get("status") ?? "new") });
  const id = Number(url.pathname.split("/").pop());
  const body = (await req.json().catch(() => ({}))) as { status?: string; reply?: string };
  if (!STATUSES.includes(body.status as Status)) return fail(400, "bad_status", `status must be one of ${STATUSES.join(", ")}`);
  const updated = Feedback.update(id, body.status as Status, body.reply?.trim() ? body.reply.trim().slice(0, 4000) : null);
  return updated ? json(updated) : fail(404, "not_found", "No such feedback.");
}

const html = (body: string, status = 200) => new Response(body, { status, headers: { "Content-Type": "text/html; charset=utf-8" } });

function googleStart(url: URL, ip: string) {
  if (!google.googleEnabled()) return html(google.page("Google sign-in is off", "Use email and password in Oneshot for now."), 503);
  if (!allow(`google:${ip}`, 30, 600_000)) return html(google.page("Slow down", "Too many sign-in attempts. Try again in a few minutes."), 429);
  const target = google.startURL(url.searchParams.get("state") ?? "", url.searchParams.get("challenge") ?? "");
  if (!target) return html(google.page("Something's off", "Start signing in again from the Oneshot app."), 400);
  return Response.redirect(target, 302);
}

async function googleCallback(url: URL, ip: string) {
  const state = url.searchParams.get("state") ?? "";
  if (url.searchParams.get("error")) {
    return html(google.page("Sign-in cancelled", "You can close this tab and try again from Oneshot.",
      `oneshot://auth?error=cancelled&state=${encodeURIComponent(state)}`));
  }
  try {
    const who = await google.finish(url.searchParams.get("code") ?? "", state);
    const user = Users.fromGoogle(who.sub, who.email, ip);
    const code = google.grant(user.id, user.email, who.challenge);
    const back = `oneshot://auth?code=${encodeURIComponent(code)}&state=${encodeURIComponent(state)}`;
    return html(google.page("You're signed in", `Welcome, ${user.email}. Heading back to Oneshot…`, back));
  } catch (e) {
    return html(google.page("Couldn't sign in", (e as Error).message), 400);
  }
}

async function exchange(req: Request) {
  const body = (await req.json().catch(() => ({}))) as { code?: string; verifier?: string };
  const g = google.redeem(String(body.code ?? ""), String(body.verifier ?? ""));
  if (!g) return fail(400, "invalid_grant", "That sign-in expired. Try again.");
  const user = { id: g.userId, email: g.email, password_hash: "" };
  return json({ token: startSession(user), email: g.email, usage: usageOf(user) });
}

const server = Bun.serve({
  port: config.port,
  maxRequestBodySize: config.maxAudioBytes + 64 * 1024,
  async fetch(req, server) {
    const url = new URL(req.url);
    const ip = clientIP(req, server);
    const route = `${req.method} ${url.pathname}`;
    try {
      if (req.method === "GET") {
        const file = serveStatic(url.pathname);
        if (file) return file;
      }
      switch (route) {
        case "GET /health": return json({ ok: true });
        case "POST /v1/auth/signup": return await signup(req, ip);
        case "POST /v1/auth/login": return await login(req, ip);
        case "GET /auth/google/start": return googleStart(url, ip);
        case "GET /auth/google/callback": return await googleCallback(url, ip);
        case "POST /v1/auth/exchange": return await exchange(req);
        case "GET /v1/auth/providers": return json({ google: google.googleEnabled() });
        case "POST /v1/feedback": return await sendFeedback(req, ip);
        case "GET /v1/feedback": return myFeedback(req);
        case "POST /v1/feedback/seen": {
          const installId = req.headers.get("x-install-id") ?? "";
          if (INSTALL.test(installId)) Feedback.markSeen(installId);
          return json({ ok: true });
        }
      }
      if (url.pathname === "/admin/feedback" || url.pathname.startsWith("/admin/feedback/")) return await adminFeedback(req, url);
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

console.log(`Oneshot server listening on :${server.port}`);
