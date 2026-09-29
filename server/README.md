# Oneshot server

Holds the OpenAI key so Oneshot users only need a free account. Bun + SQLite, no dependencies.

| Route | |
| --- | --- |
| `POST /v1/auth/signup`, `POST /v1/auth/login` | `{email, password}` → `{token, email, usage}` |
| `GET /v1/me`, `POST /v1/auth/logout` | Bearer token |
| `POST /v1/dictate` | multipart `audio` + `meta` JSON → transcribes, cleans up (or runs a command), returns `{raw, text, usage}` |

Passwords are hashed with argon2id; only the SHA-256 of each session token is stored. Abuse limits: 5 sign-ups per IP per hour, login throttling per IP and email, 30 dictations per user per minute, 3 hours per recording (sent as 5-minute parts), `FREE_DAILY_SECONDS` per user per UTC day (30 min) and `GLOBAL_DAILY_SECONDS` across everyone (10 h, about US$4/day of transcription). Audio and text are never stored or logged.

```sh
OPENAI_API_KEY=sk-... bun start     # http://localhost:8787
bun test                            # integration tests against a mock OpenAI
./deploy.sh                         # Fly.io (São Paulo), then rebuilds the app pointing at it
```
