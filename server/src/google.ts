import { config } from "./config";

/**
 * Google sign-in for the desktop app, with PKCE between the app and this server:
 *   app  -> GET /auth/google/start?state&challenge   (opens in the browser)
 *   here -> Google consent -> GET /auth/google/callback
 *   here -> murmur://auth?code&state                  (one-time code, 5 minutes)
 *   app  -> POST /v1/auth/exchange {code, verifier}   -> session token
 */
type Pending = { challenge: string; created: number };
type Grant = { userId: number; email: string; challenge: string; created: number };

const pending = new Map<string, Pending>();
const grants = new Map<string, Grant>();
const TTL = 5 * 60_000;

setInterval(() => {
  const now = Date.now();
  for (const [k, v] of pending) if (now - v.created > TTL * 2) pending.delete(k);
  for (const [k, v] of grants) if (now - v.created > TTL) grants.delete(k);
}, 60_000).unref?.();

export const googleEnabled = () => Boolean(config.googleClientId && config.googleClientSecret);
const redirectURI = () => `${config.publicURL}/auth/google/callback`;
export const challengeOf = (verifier: string) =>
  Buffer.from(new Bun.CryptoHasher("sha256").update(verifier).digest()).toString("base64url");

export function startURL(state: string, challenge: string): string | null {
  if (!/^[A-Za-z0-9_-]{16,128}$/.test(state) || !/^[A-Za-z0-9_-]{43}$/.test(challenge)) return null;
  pending.set(state, { challenge, created: Date.now() });
  const u = new URL(config.googleAuthURL);
  u.search = new URLSearchParams({
    client_id: config.googleClientId,
    redirect_uri: redirectURI(),
    response_type: "code",
    scope: "openid email profile",
    state,
    prompt: "select_account",
  }).toString();
  return u.toString();
}

/** Exchanges Google's code; returns the verified identity and the app's challenge. */
export async function finish(code: string, state: string) {
  const p = pending.get(state);
  pending.delete(state);
  if (!p || Date.now() - p.created > TTL * 2) throw new Error("This sign-in link expired. Start again from Murmur.");
  const res = await fetch(config.googleTokenURL, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      code, client_id: config.googleClientId, client_secret: config.googleClientSecret,
      redirect_uri: redirectURI(), grant_type: "authorization_code",
    }),
    signal: AbortSignal.timeout(15_000),
  });
  const body = (await res.json().catch(() => ({}))) as { id_token?: string; error_description?: string };
  if (!res.ok || !body.id_token) throw new Error(body.error_description ?? "Google didn't accept the sign-in.");
  // The ID token came straight from Google's token endpoint over TLS, authenticated with
  // our client secret, so its claims can be trusted without re-checking the signature.
  const claims = JSON.parse(Buffer.from(body.id_token.split(".")[1] ?? "", "base64url").toString("utf8")) as {
    sub?: string; email?: string; email_verified?: boolean; aud?: string;
  };
  if (claims.aud !== config.googleClientId) throw new Error("Unexpected Google audience.");
  if (!claims.sub || !claims.email || !claims.email_verified) throw new Error("Your Google email isn't verified.");
  return { sub: claims.sub, email: claims.email.toLowerCase(), challenge: p.challenge };
}

export function grant(userId: number, email: string, challenge: string) {
  const code = Buffer.from(crypto.getRandomValues(new Uint8Array(24))).toString("base64url");
  grants.set(code, { userId, email, challenge, created: Date.now() });
  return code;
}

export function redeem(code: string, verifier: string) {
  const g = grants.get(code);
  grants.delete(code);
  if (!g || Date.now() - g.created > TTL) return null;
  if (challengeOf(verifier) !== g.challenge) return null;
  return g;
}

const esc = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

export function page(title: string, message: string, appURL?: string) {
  const open = appURL
    ? `<a class="btn" href="${esc(appURL)}">Open Murmur</a><script>setTimeout(()=>{location.href=${JSON.stringify(appURL)}},150)</script>`
    : "";
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>${esc(title)}</title>
<style>
  body{margin:0;min-height:100vh;display:grid;place-items:center;font:15px/1.5 -apple-system,system-ui,sans-serif;background:#f5f4fa;color:#1d1b2e}
  .card{background:#fff;border-radius:20px;padding:40px 44px;max-width:380px;text-align:center;box-shadow:0 1px 2px rgba(0,0,0,.06),0 12px 40px rgba(60,40,160,.12)}
  .logo{width:64px;height:64px;border-radius:17px;margin:0 auto 18px;background:linear-gradient(135deg,#6b59fa,#3d2e9e)}
  h1{font-size:21px;margin:0 0 6px}p{color:#5b5870;margin:0 0 22px}
  a.btn{display:inline-block;background:#6b59fa;color:#fff;text-decoration:none;font-weight:600;padding:10px 20px;border-radius:10px}
</style></head><body><div class="card"><div class="logo"></div><h1>${esc(title)}</h1><p>${esc(message)}</p>${open}</div></body></html>`;
}
