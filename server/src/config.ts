export const config = {
  port: Number(process.env.PORT ?? 8787),
  openaiKey: process.env.OPENAI_API_KEY ?? "",
  openaiBase: process.env.OPENAI_BASE_URL ?? "https://api.openai.com/v1",
  databasePath: process.env.DATABASE_PATH ?? "./data/murmur.db",
  freeDailySeconds: Number(process.env.FREE_DAILY_SECONDS ?? 1800),
  globalDailySeconds: Number(process.env.GLOBAL_DAILY_SECONDS ?? 36000),
  /** Longest single dictation. The app splits recordings into ~10 minute parts. */
  maxAudioSeconds: Number(process.env.MAX_AUDIO_SECONDS ?? 3 * 3600),
  /** Whole request (3 h of 24 kbps AAC is ~33 MB). */
  maxAudioBytes: 48 * 1024 * 1024,
  /** One part sent to OpenAI (its limit is 25 MB and ~25 minutes). */
  maxPartBytes: 24 * 1024 * 1024,
  maxPartSeconds: 20 * 60,
  transcribeModel: process.env.TRANSCRIBE_MODEL ?? "gpt-4o-transcribe",
  cleanupModel: process.env.CLEANUP_MODEL ?? "gpt-5.4-mini",
  commandModel: process.env.COMMAND_MODEL ?? "gpt-5.4-mini",
  publicURL: (process.env.PUBLIC_URL ?? "http://localhost:8787").replace(/\/$/, ""),
  adminToken: process.env.ADMIN_TOKEN ?? "",
  googleClientId: process.env.GOOGLE_CLIENT_ID ?? "",
  googleClientSecret: process.env.GOOGLE_CLIENT_SECRET ?? "",
  googleAuthURL: process.env.GOOGLE_AUTH_URL ?? "https://accounts.google.com/o/oauth2/v2/auth",
  googleTokenURL: process.env.GOOGLE_TOKEN_URL ?? "https://oauth2.googleapis.com/token",
};
