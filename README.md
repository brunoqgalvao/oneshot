# Murmur

Voice dictation for macOS that works in any app, in the style of Wispr Flow. Hold **fn**, talk, release: the transcript is cleaned up by an LLM and pasted where your cursor is.

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
4. **Transcription**: OpenAI `gpt-4o-transcribe` (configurable), biased with your vocabulary. If the network fails it falls back to Apple's on-device recognizer.
5. **Cleanup**: `gpt-5.4-mini` with reasoning off removes fillers, applies self-corrections ("at 2, actually 3" -> "at 3"), handles "new line"/lists, and adapts tone to the destination (chat, email, code, AI prompt, docs). A guard falls back to the raw transcript if the model answers instead of cleaning.
6. **Insert**: the text goes on the pasteboard (marked transient so clipboard managers ignore it), ⌘V is sent, and your previous clipboard is restored.

## Build

Requires the Xcode Command Line Tools (Swift 5.9+), macOS 13+.

```sh
./build.sh --open
```

The first build creates a self-signed identity in `.signing/` so macOS keeps the Accessibility and Microphone permissions across rebuilds.

The OpenAI key is stored in `~/Library/Application Support/Murmur/openai.key` (mode 600). Enter it in Setup, or import it from your shell with `build/Murmur.app/Contents/MacOS/Murmur --import-env-key`.

Test the pipeline without the mic:

```sh
build/Murmur.app/Contents/MacOS/Murmur --transcribe clip.wav --app com.tinyspeck.slackmacgap
```
