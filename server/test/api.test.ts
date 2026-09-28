import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// A fake OpenAI so the test is fast, free and deterministic.
let lastChatUser = "";
const mock = Bun.serve({
  port: 0,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === "/token") {
      // Fake Google: the code carries the email we want back.
      const form = await req.formData();
      const email = String(form.get("code")).replace("google:", "");
      const payload = Buffer.from(JSON.stringify({ aud: "test-client", sub: "g-" + email, email, email_verified: true })).toString("base64url");
      return Response.json({ id_token: "x." + payload + ".y" });
    }
    if (url.pathname.endsWith("/audio/transcriptions")) return Response.json({ text: "um so hello there uh new line thanks" });
    if (url.pathname.endsWith("/chat/completions")) {
      const body: any = await req.json();
      lastChatUser = body.messages[1].content;
      const cmd = body.messages[0].content.includes("command mode");
      return Response.json({ choices: [{ message: { content: cmd ? "Rewritten." : "So hello there.\nThanks." } }] });
    }
    return new Response("nope", { status: 404 });
  },
});

const dir = mkdtempSync(join(tmpdir(), "murmur-test-"));
const port = 18000 + Math.floor(Math.random() * 1000);
const base = `http://127.0.0.1:${port}`;
let proc: ReturnType<typeof Bun.spawn>;

beforeAll(async () => {
  proc = Bun.spawn(["bun", "src/index.ts"], {
    cwd: join(import.meta.dir, ".."),
    env: { ...process.env, PORT: String(port), OPENAI_API_KEY: "test", OPENAI_BASE_URL: `http://127.0.0.1:${mock.port}`,
      DATABASE_PATH: join(dir, "t.db"), FREE_DAILY_SECONDS: "10",
      PUBLIC_URL: base, ADMIN_TOKEN: "a".repeat(40), GOOGLE_CLIENT_ID: "test-client", GOOGLE_CLIENT_SECRET: "secret",
      GOOGLE_AUTH_URL: `http://127.0.0.1:${mock.port}/auth`, GOOGLE_TOKEN_URL: `http://127.0.0.1:${mock.port}/token` },
    stdout: "ignore", stderr: "inherit",
  });
  for (let i = 0; i < 50; i++) {
    try { if ((await fetch(`${base}/health`)).ok) return; } catch {}
    await Bun.sleep(100);
  }
  throw new Error("server did not start");
});

afterAll(() => { proc?.kill(); mock.stop(true); rmSync(dir, { recursive: true, force: true }); });

const post = (path: string, body: unknown, token?: string) =>
  fetch(base + path, { method: "POST", headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) });

function dictation(token: string, meta: Record<string, unknown>) {
  const form = new FormData();
  form.append("audio", new File([new Uint8Array(2000)], "a.m4a", { type: "audio/mp4" }));
  form.append("meta", JSON.stringify(meta));
  return fetch(base + "/v1/dictate", { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: form });
}

let token = "";

test("sign up validates input and creates a session", async () => {
  expect((await post("/v1/auth/signup", { email: "nope", password: "longenough" })).status).toBe(400);
  expect((await post("/v1/auth/signup", { email: "a@b.co", password: "short" })).status).toBe(400);
  const res = await post("/v1/auth/signup", { email: "Bruno@Example.com", password: "correct horse" });
  expect(res.status).toBe(201);
  const body: any = await res.json();
  expect(body.email).toBe("bruno@example.com");
  expect(body.token).toStartWith("mur_");
  expect(body.usage.limitSeconds).toBe(10);
  token = body.token;
  expect((await post("/v1/auth/signup", { email: "bruno@example.com", password: "another one" })).status).toBe(409);
});

test("login rejects a wrong password and accepts the right one", async () => {
  expect((await post("/v1/auth/login", { email: "bruno@example.com", password: "wrong password" })).status).toBe(401);
  expect((await post("/v1/auth/login", { email: "nobody@example.com", password: "whatever1" })).status).toBe(401);
  const res = await post("/v1/auth/login", { email: "bruno@example.com", password: "correct horse" });
  expect(res.status).toBe(200);
});

test("protected routes need a valid token", async () => {
  expect((await fetch(base + "/v1/me")).status).toBe(401);
  expect((await fetch(base + "/v1/me", { headers: { Authorization: "Bearer mur_fake" } })).status).toBe(401);
  const me: any = await (await fetch(base + "/v1/me", { headers: { Authorization: `Bearer ${token}` } })).json();
  expect(me.email).toBe("bruno@example.com");
});

test("dictate transcribes, cleans up with context, and counts usage", async () => {
  const res = await dictation(token, { durationSeconds: 6, destination: "chat", appName: "Slack", contextBefore: "hey Ana,", vocabulary: ["Folio"] });
  expect(res.status).toBe(200);
  const body: any = await res.json();
  expect(body.raw).toBe("um so hello there uh new line thanks");
  expect(body.text).toBe("So hello there.\nThanks.");
  expect(body.usage.usedSeconds).toBe(6);
  expect(lastChatUser).toContain("Slack");
  expect(lastChatUser).toContain("hey Ana,");
  expect(lastChatUser).toContain("Folio");
});

test("command mode uses the command prompt", async () => {
  const body: any = await (await dictation(token, { mode: "command", durationSeconds: 1, selection: "some text" })).json();
  expect(body.mode).toBe("command");
  expect(body.text).toBe("Rewritten.");
  expect(lastChatUser).toContain("some text");
});

test("the daily free limit is enforced", async () => {
  const res = await dictation(token, { durationSeconds: 6 });
  expect(res.status).toBe(429);
  expect(((await res.json()) as any).error).toBe("daily_limit");
});

test("logout revokes the token", async () => {
  expect((await post("/v1/auth/logout", {}, token)).status).toBe(200);
  expect((await fetch(base + "/v1/me", { headers: { Authorization: `Bearer ${token}` } })).status).toBe(401);
});


// --- Google sign-in -------------------------------------------------------

async function googleSignIn(email: string, verifier = "v".repeat(43)) {
  const state = "state-" + Math.random().toString(36).slice(2, 12);
  const challenge = new Bun.CryptoHasher("sha256").update(verifier).digest("base64url");
  const start = await fetch(`${base}/auth/google/start?state=${state}&challenge=${challenge}`, { redirect: "manual" });
  expect(start.status).toBe(302);
  const to = new URL(start.headers.get("location")!);
  expect(to.searchParams.get("redirect_uri")).toBe(`${base}/auth/google/callback`);
  expect(to.searchParams.get("state")).toBe(state);
  const cb = await fetch(`${base}/auth/google/callback?code=google:${email}&state=${state}`);
  const page = await cb.text();
  const m = page.match(/oneshot:\/\/auth\?code=([^&"]+)&amp;state=([^"&]+)/);
  expect(m?.[2]).toBe(state);
  return decodeURIComponent(m![1]);
}

test("google sign-in exchanges a one-time code only with the right verifier", async () => {
  const code = await googleSignIn("New.Person@gmail.com");
  expect((await post("/v1/auth/exchange", { code, verifier: "w".repeat(43) })).status).toBe(400);
  // The code is single-use, even after a failed attempt.
  expect((await post("/v1/auth/exchange", { code, verifier: "v".repeat(43) })).status).toBe(400);
  const code2 = await googleSignIn("New.Person@gmail.com");
  const res = await post("/v1/auth/exchange", { code: code2, verifier: "v".repeat(43) });
  expect(res.status).toBe(200);
  const body: any = await res.json();
  expect(body.email).toBe("new.person@gmail.com");
  expect(body.token).toStartWith("mur_");
});

test("google sign-in links to an existing email account", async () => {
  const signup: any = await (await post("/v1/auth/signup", { email: "both@example.com", password: "a-password" })).json();
  const code = await googleSignIn("both@example.com");
  const g: any = await (await post("/v1/auth/exchange", { code, verifier: "v".repeat(43) })).json();
  const me1: any = await (await fetch(base + "/v1/me", { headers: { Authorization: `Bearer ${signup.token}` } })).json();
  const me2: any = await (await fetch(base + "/v1/me", { headers: { Authorization: `Bearer ${g.token}` } })).json();
  expect(me2.email).toBe(me1.email);
  // Password login still works for the linked account; Google-only accounts can't use one.
  expect((await post("/v1/auth/login", { email: "both@example.com", password: "a-password" })).status).toBe(200);
  expect((await post("/v1/auth/login", { email: "new.person@gmail.com", password: "anything1" })).status).toBe(401);
});


// --- Feedback loop ---------------------------------------------------------

test("feedback: anyone can send, only admins list, replies reach the sender", async () => {
  const install = "install-" + "x".repeat(24);
  const other = "install-" + "y".repeat(24);
  const send = (text: string, id = install) =>
    fetch(base + "/v1/feedback", { method: "POST", headers: { "Content-Type": "application/json", "X-Install-Id": id }, body: JSON.stringify({ text, context: { appVersion: "0.2.0" } }) });
  expect((await send("")).status).toBe(400);
  const r = await send("Please add a shortcut to paste the last dictation");
  expect(r.status).toBe(201);
  const { id } = (await r.json()) as any;
  await send("other person's idea", other);

  const admin = { Authorization: "Bearer " + "a".repeat(40), "Content-Type": "application/json" };
  expect((await fetch(base + "/admin/feedback")).status).toBe(401);
  expect((await fetch(base + "/admin/feedback", { headers: { Authorization: "Bearer wrong" } })).status).toBe(401);
  const list: any = await (await fetch(base + "/admin/feedback?status=new", { headers: admin })).json();
  expect(list.items.map((f: any) => f.text)).toContain("Please add a shortcut to paste the last dictation");

  expect((await fetch(base + "/admin/feedback/" + id, { method: "POST", headers: admin, body: JSON.stringify({ status: "nope" }) })).status).toBe(400);
  const upd = await fetch(base + "/admin/feedback/" + id, { method: "POST", headers: admin, body: JSON.stringify({ status: "shipped", reply: "Done! It's in 0.2.1." }) });
  expect(upd.status).toBe(200);

  const mine: any = await (await fetch(base + "/v1/feedback", { headers: { "X-Install-Id": install } })).json();
  expect(mine.items).toHaveLength(1);
  expect(mine.items[0]).toMatchObject({ status: "shipped", reply: "Done! It's in 0.2.1.", seen: false });
  expect(mine.items[0].install_id).toBeUndefined();
  await fetch(base + "/v1/feedback/seen", { method: "POST", headers: { "X-Install-Id": install } });
  const after: any = await (await fetch(base + "/v1/feedback", { headers: { "X-Install-Id": install } })).json();
  expect(after.items[0].seen).toBe(true);
});
