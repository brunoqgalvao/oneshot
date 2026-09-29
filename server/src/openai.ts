import { config } from "./config";
import { Spend } from "./db";

export class UpstreamError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

async function check(res: Response) {
  if (res.ok) return res.json() as Promise<any>;
  let msg = res.statusText;
  try { msg = ((await res.json()) as any)?.error?.message ?? msg; } catch {}
  throw new UpstreamError(res.status, msg);
}

export async function transcribe(audio: File, opts: { prompt?: string; language?: string }) {
  const form = new FormData();
  form.append("model", config.transcribeModel);
  form.append("response_format", "json");
  if (opts.prompt) form.append("prompt", opts.prompt);
  if (opts.language && opts.language !== "auto") form.append("language", opts.language);
  form.append("file", audio, audio.name || "audio.m4a");
  const res = await fetch(`${config.openaiBase}/audio/transcriptions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${config.openaiKey}` },
    body: form,
    signal: AbortSignal.timeout(180_000),
  });
  return String((await check(res)).text ?? "");
}

export async function chat(model: string, system: string, user: string, maxTokens = 2000) {
  const body: Record<string, unknown> = {
    model,
    messages: [{ role: "system", content: system }, { role: "user", content: user }],
  };
  if (model.startsWith("gpt-5") || model.startsWith("o")) {
    body.reasoning_effort = model === "gpt-5" || model.startsWith("gpt-5-") ? "minimal" : "none";
    body.max_completion_tokens = maxTokens;
  } else {
    body.temperature = 0;
    body.max_tokens = maxTokens;
  }
  const res = await fetch(`${config.openaiBase}/chat/completions`, {
    method: "POST",
    headers: { Authorization: `Bearer ${config.openaiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(90_000),
  });
  const data = await check(res);
  Spend.tokens(Number(data.usage?.prompt_tokens) || 0, Number(data.usage?.completion_tokens) || 0);
  return String(data.choices?.[0]?.message?.content ?? "");
}
