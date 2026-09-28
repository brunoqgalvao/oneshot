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
      DATABASE_PATH: join(dir, "t.db"), FREE_DAILY_SECONDS: "10" },
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
