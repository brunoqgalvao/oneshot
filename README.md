# Murmur

Voice dictation for macOS that works in any app, in the style of Wispr Flow. Hold **fn**, talk, release: the transcript is cleaned up by an LLM and pasted where your cursor is.

Users sign up for a free Murmur account inside the app (email + password); the [server](server/README.md) holds the OpenAI key, runs transcription and cleanup, and enforces a daily free allowance. Bringing your own OpenAI key, or transcribing fully on-device, are options in Settings → AI.

## Use

| Keys | What happens |
| --- | --- |
| Hold fn | Dictate; release to insert |
| Double-tap fn, or fn + Space | Hands-free; tap fn (or the red button) to finish |
| Hold ⌃ Control while dictating | Command mode: rewrites the selected text, or writes something new |
| Esc | Cancel |

The key can be changed to Right ⌥ or Right ⌘ in Settings → General. Recent dictations are in the menu bar icon and in Settings → History.

URL scheme for Shortcuts/Raycast: `murmur://toggle`, `start`, `stop`, `cancel`, `command`, `settings`.

## How it works

1. **Hotkey**: a `CGEventTap` watches modifier changes for the chosen key and swallows Space/Esc only while dictating.
2. **Context**: when you press the key, the Accessibility API reads the frontmost app, window title, up to 600 characters before the cursor and any selection. Password fields are detected and skipped.
3. **Audio**: `AVAudioEngine` records 16 kHz mono and drives the waveform; the clip is encoded to AAC (~6x smaller than WAV) before upload. The TLS connection is opened when recording starts.
4. **Transcription + cleanup**: one upload to the Murmur server (`POST /v1/dictate`), which calls OpenAI `gpt-4o-transcribe` biased with your vocabulary, then `gpt-5.4-mini` with reasoning off to remove fillers, apply self-corrections ("at 2, actually 3" -> "at 3"), handle "new line"/lists and adapt tone to the destination (chat, email, code, AI prompt, docs). A guard falls back to the raw transcript if the model answers instead of cleaning. If the server is unreachable, Apple's on-device recognizer takes over.
5. **Account**: the session token lives in `~/Library/Application Support/Murmur/session.token` (mode 600); the menu shows today's free minutes left.
6. **Insert**: the text goes on the pasteboard (marked transient so clipboard managers ignore it), ⌘V is sent, and your previous clipboard is restored.

## Build

Requires the Xcode Command Line Tools (Swift 5.9+), macOS 13+.

```sh
./build.sh --open
```

The app talks to `http://localhost:8787` until the server is deployed. Run it locally with `cd server && OPENAI_API_KEY=sk-... bun start`, or deploy with `server/deploy.sh`, which writes the public URL to `.server-url` and rebuilds the app against it.

The first build creates a self-signed identity in `.signing/` so macOS keeps the Accessibility and Microphone permissions across rebuilds.

Test the pipeline without the mic:

```sh
BIN=build/Murmur.app/Contents/MacOS/Murmur
$BIN --signup you@example.com 'a-password'      # or --login
$BIN --transcribe clip.wav --app com.tinyspeck.slackmacgap
```
