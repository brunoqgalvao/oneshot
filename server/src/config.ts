export const config = {
  port: Number(process.env.PORT ?? 8787),
  openaiKey: process.env.OPENAI_API_KEY ?? "",
  openaiBase: process.env.OPENAI_BASE_URL ?? "https://api.openai.com/v1",
  databasePath: process.env.DATABASE_PATH ?? "./data/murmur.db",
  freeDailySeconds: Number(process.env.FREE_DAILY_SECONDS ?? 1800),
  globalDailySeconds: Number(process.env.GLOBAL_DAILY_SECONDS ?? 36000),
  maxAudioSeconds: 300,
  maxAudioBytes: 8 * 1024 * 1024,
  transcribeModel: process.env.TRANSCRIBE_MODEL ?? "gpt-4o-transcribe",
  cleanupModel: process.env.CLEANUP_MODEL ?? "gpt-5.4-mini",
  commandModel: process.env.COMMAND_MODEL ?? "gpt-5.4-mini",
};
