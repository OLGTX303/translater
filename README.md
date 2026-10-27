# Translater

Live **Malay → English** subtitles on iPad and iPhone. Speech is transcribed on the device with
[WhisperKit](https://github.com/argmaxinc/WhisperKit), translated line by line, and shown as synced,
Apple Music–style lyrics on a Tesla-style dashboard. Sessions are recorded and can be replayed or
exported as SRT / WebVTT subtitles.

Tested on an 11-inch iPad Pro (M2, iPadOS 26.2) with a 200 words-per-minute Malay news clip: it keeps up
in real time with a word error rate of about 4%.

## Features

- **On-device speech recognition**: Whisper large-v3-turbo (fast) or large-v3 (accurate) on the Neural
  Engine. Malay is detected per utterance; other languages are marked `[other language: xx]`
  instead of being forced into Malay.
- **Sentence-accurate lines**: lines are rebuilt from Whisper's word timings so each one runs from
  sentence end to sentence end; an unfinished sentence is held back and re-read with the audio that
  follows instead of being cut in half.
- **Three translators**, switchable in Settings:
  - **Server**: NLLB-200 on your own box (see [`Server/`](Server)), about 1 s per line, keeps the
    device cool; falls back to Apple Translate when unreachable.
  - **Apple Translate**: on-device, needs the Malay (or Indonesian) language pack.
  - **Whisper large-v3**: translates the audio itself; heavier, rationed when the device runs hot.
- **Two pipelines that never block each other**: recognition and translation run as separate
  actors; when translation falls behind it drops to the newest lines rather than queueing.
- **Synced display**: active line large and centred, word-by-word highlight when timings exist,
  tilted "road" view, words-per-minute card and a session map. Respects Reduce Motion.
- **Recording and replay**: AAC recording at the mic's native rate, Voice Memos-style player
  (waveform scrubbing, ±15 s, 0.5×–2×), tap a line to jump.
- **Subtitle export**: SRT and WebVTT, Malay-only or bilingual, `[unclear]` lines kept and marked,
  word-level `<c>` tags in WebVTT.
- **Custom words**: names and places (e.g. `Lembah Klang, Putrajaya`) steer Whisper's spelling.
- **Built-in 200 wpm speed test** reporting delay behind the speaker and word error rate.

## Layout

```
Core/                     Platform-free Swift package: timeline, pipelines, subtitle export (+ tests)
Sources/Translater/       The iOS app (SwiftUI)
  RecorderActor.swift       mic → voice activity → WhisperKit → sentence lines
  SessionTimeline (Core)    the store both pipelines feed; the UI reads only this
  ServerTranslator.swift    HTTPS client for Server/
  AppleTranslator.swift     Apple Translation framework
  WhisperTranslator.swift   Whisper's translate task
  ModelStore.swift          one-time model download into Application Support
  Dashboard.swift, LyricsView.swift, RecordingPlayer.swift
Server/                   NLLB-200 translation service (Docker) + example nginx site
SelfTest/                 Speed-test script and the clip generator
```

## Building

The app is a SwiftPM package built with [xtool](https://github.com/xtool-org/xtool), so it builds on
Linux as well as macOS. Xcode works too (`xtool dev generate-xcode-project`).

1. Install xtool and its Darwin SDK, and sign in (`xtool setup`).
2. Generate the speed-test clip: `sh SelfTest/make-clip.sh`.
3. Create `Sources/Translater/ServerSecret.swift` (git-ignored):

   ```swift
   enum ServerSecret {
       static let token = "<the TOKEN from your server's env file>"
   }
   ```

   If you don't run the server, any string works; the app falls back to Apple Translate.
4. Point `ServerTranslator.endpoint` at your server.
5. Connect the device and run `xtool dev run`.

The Whisper models are not bundled. On the first session the app downloads them once (about 600 MB
for turbo, 950 MB for large-v3) into Application Support, where they survive app updates.

`Package.swift` passes `-platform_version ios 17.0 27.1` to the linker so the binary is stamped with
the real SDK version; without it iOS runs the app in compatibility mode without Liquid Glass. Keep the
second number in step with your xtool SDK.

### Core tests

The core package has no Apple-only dependencies, so its tests run anywhere Swift does:

```bash
cd Core && swift test
```

They round-trip a sample session through SRT and WebVTT, check that a slow translator never delays
recognition, and check that cancelling a session stops both pipelines.

## Translation server

`Server/` is a small Python service running Meta's NLLB-200 600M (int8, CTranslate2) on the CPU.
About 0.9 s per line on an Intel N100, using roughly 700 MiB of RAM.

```bash
# model (pre-converted to CTranslate2 int8)
mkdir -p /opt/translater-mt/model && cd /opt/translater-mt/model
for f in config.json model.bin sentencepiece.bpe.model shared_vocabulary.txt special_tokens_map.json; do
  curl -fLO "https://huggingface.co/JustFrederik/nllb-200-distilled-600M-ct2-int8/resolve/main/$f"
done
# secret token
cd /opt/translater-mt && (umask 077; python3 -c 'import secrets; print("TOKEN=" + secrets.token_urlsafe(32))' > env)
# build and run (copy Server/app.py and Server/Dockerfile here first)
docker build -t translater-mt .
docker run -d --name translater-mt --restart unless-stopped -p 127.0.0.1:8700:8700 \
  -v /opt/translater-mt/model:/model:ro --env-file /opt/translater-mt/env \
  --memory 2g --cpus 3 translater-mt
```

API: `POST /translate` with `Authorization: Bearer <TOKEN>` and `{"text": "...", "source": "ms"}`
returns `{"english": "...", "ms": 312}`; `GET /health` returns `{"ok": true}`.

Put it behind HTTPS (iOS requires it for public hosts). `Server/translate.olgtx.com.conf` is an
example nginx site behind Cloudflare with per-client rate limiting; adjust the server name.

## Licenses

The code in this repository is licensed under the [Apache License 2.0](LICENSE).

The models it downloads have their own licenses:

- Whisper (OpenAI) and the WhisperKit Core ML conversions: MIT.
- NLLB-200 (Meta), used by the translation server: **CC-BY-NC 4.0, non-commercial use only.**
  Replace it with another model for commercial use.
- The speed-test clip is synthesised locally with Microsoft's edge-tts voices and is not included.
