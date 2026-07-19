# Tomato English Happy Talking

[English](README.md) | [中文](README.zh-CN.md)

Tomato English Happy Talking is a standalone Flutter app for AI-assisted
English listening, speaking, picture-book, song, and video practice.

It runs without a private backend. The Windows and Android clients call the
configured cloud AI services directly, while all learning content, generated
assets, playback cache, diagnostics, and user settings stay on the local device.

The project is open sourced under the Apache License 2.0. See
[LICENSE](LICENSE) for details. Cloud services, third-party models, fonts,
media, and generated user content remain subject to their own terms.

## Author And Origin

- Author: 兔子先生 / Ryan Chen
- Email: [70565912@qq.com](mailto:70565912@qq.com)

This app began as an AI English practice tool that 兔子先生 built for his child
「番茄」(Tomato). The design goal is to turn arbitrary articles into English
picture-book learning videos, and to support everyday listening / speaking
practice. Because the features call paid cloud APIs, you must apply for the
corresponding API keys and configure them in the app before normal use.
Application URLs and setup steps are included further below.

## What It Does

- Imports English or bilingual text and saves it as book chapters.
- Organizes learning material around books, chapters, listening, shadowing, and
  conversation practice.
- Generates picture-book scenes for a full chapter after a prompt review step.
- Creates or imports song versions for chapter lyrics, then builds subtitle
  timelines from ASR timing.
- Plays chapter audio with cached TTS and optional full-screen picture-book
  playback.
- Supports follow-read recording and recognition-based pronunciation scoring.
- Provides English conversation practice based on chapter content.
- Exports listening and song videos with SRT or burned-in subtitles.
- Stores settings locally and avoids returning plaintext API keys through the
  Flutter/Web bridge.

## Screenshots

Creation Center: manage picture books, songs, and video export per chapter.

![Creation Center](docs/readme/creation-center.png)

Practice Center: open listening, follow-read, and conversation practice by book.

![Practice Center](docs/readme/practice-center.png)

## Download

Ship builds are on GitHub Releases:

- [Latest release](https://github.com/70565912/TomatoEnglishHappyTalking/releases/latest)
- Windows zip and Android APK are attached per tag (for example `v1.0.0`)

## Apply And Configure API Keys

This repository does **not** ship any cloud credentials. After install, open
**Settings → Cloud services** in the app and paste your keys there (the UI
stores them securely and only returns masked status over the bridge). Cloud
calls are billed by each provider—read their pricing before enabling features.

### Which keys you need

| Label in Settings | Used for | Required? |
| --- | --- | --- |
| **Bailian Key** | Default Aliyun path: text, picture-book groups, TTS, ASR, Bailian Fun-Music | Required when using Aliyun (the default platform) |
| **Ark Key** | Volcengine path: Ark text, Seedream picture-book groups | Required when using Volcengine text / images |
| **Speech Key** | Volcengine TTS / BigASR; conversation practice uses Realtime speech | Required for Volcengine speech, follow-read ASR on Volc, or conversation |

Recommended start: create and configure the **Bailian Key** first so you can
import chapters, generate picture books, and use listening / most creation
flows. Add **Ark Key** and **Speech Key** when you switch to Volcengine or need
conversation practice.

Suno does not use an in-app API key: choose Suno in settings, complete generate
/ download in the system browser with your own Suno account, then import the
local MP3 from Creation Center.

### Where to apply

1. **Aliyun Bailian (DashScope) API Key**
   - Console: [Bailian API Key management](https://bailian.console.aliyun.com/?tab=model#/api-key)
   - Guide: [Get an API Key](https://help.aliyun.com/zh/model-studio/get-api-key)
   - Copy the key immediately when created; plaintext is usually not shown again.
2. **Volcengine Ark API Key**
   - Console: [Ark API Key](https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey)
   - Enable Ark and the text / image models you plan to use (for example Seedream
     sequential images).
3. **Volcengine Speech API Key (new console)**
   - Console: [Doubao Speech · API Key management](https://console.volcengine.com/speech/new/setting/apikeys)
   - Guide: [Console API Key management](https://www.volcengine.com/docs/6561/2119699)
   - This app uses the new `X-Api-Key` auth style; enable TTS / ASR / Realtime as
     needed before calling those features.

### Configure inside the app

1. Install and launch the Windows or Android app.
2. Open **Settings → Cloud services**.
3. In **Credentials**, paste **Bailian Key**, **Ark Key**, and **Speech Key** for
   the providers you actually use (leave unused fields empty).
4. Set the active **platform** to Aliyun Bailian or Volcengine to match those
   keys.
5. Save. New remote generations use the current provider; existing local cache
   is reused first.

Never commit keys, paste them into issues / screenshots / logs, or ship local
`security/` / `settings.json` inside a public Windows zip.

## Current Platforms

- Windows desktop app: `tomato_english_happy_talking.exe`
- Android APK: `com.example.tomato_english_happy_talking`

The main UI is a bundled React/Vite WebView. Flutter owns native capabilities
such as local storage, secure settings, recording, playback, TTS, ASR, AI calls,
and file export.

## Architecture

```text
TomatoEnglishHappyTalking/
├── app/                  # Flutter app
│   ├── lib/              # Dart source
│   ├── assets/web/       # Built Web UI bundled into the app
│   ├── android/          # Android platform project
│   └── windows/          # Windows platform project
├── web_ui/               # React + Vite + TypeScript UI
├── tools/                # Build and local automation scripts
├── docs/                 # Design notes, migration notes, and change log
├── README.md             # English
└── README.zh-CN.md       # 中文
```

Runtime flow:

```text
React/Vite Web UI
        |
        | typed bridge commands/events
        v
Flutter WebShellScreen
        |
        +-- Riverpod providers
        +-- local SQLite and secure storage
        +-- recording and playback services
        +-- cloud AI service clients
        +-- export and diagnostic tooling
```

## Cloud Services

The app can be configured to use different providers for text, image, speech,
ASR, and music generation.

| Area | Supported provider path |
| --- | --- |
| Text generation | Aliyun Bailian OpenAI-compatible Chat Completions, Volcengine Ark |
| Picture-book images | Aliyun Wanxiang sequential images, Volcengine Seedream sequential images |
| TTS | Aliyun CosyVoice, Volcengine Doubao TTS 2.0 |
| ASR | Aliyun Qwen-ASR, Volcengine BigASR |
| Realtime conversation | Volcengine Realtime dialogue |
| Song generation | Aliyun Bailian Fun-Music; Suno via system-browser manual import |

API keys are not included in this repository. Configure them from the app
settings page during local use. Do not commit keys, exported diagnostics, local
databases, generated media, or release runtime data.

## Requirements

The repository is developed on Windows. Other environments may work, but the
provided release scripts are PowerShell-based.

- Flutter stable SDK
- Dart SDK included with Flutter
- Node.js and npm for `web_ui/`
- Android SDK for APK builds
- Microsoft Edge WebView2 Runtime for the Windows app
- FFmpeg for video/audio export in the packaged Windows runtime

The original development machine uses Flutter under `D:\DevTools\flutter` and
Android SDK under `D:\Android\SDK`, but those paths are local conventions rather
than repository requirements.

## Quick Start

Install Flutter dependencies:

```powershell
cd app
flutter pub get
```

Install and build the Web UI:

```powershell
cd web_ui
npm install
npm run build
```

Build the Windows app from the repository root:

```powershell
.\tools\build_windows.ps1 -Release
```

Build the Android release APK:

```powershell
.\tools\build_android.ps1
```

Publish a GitHub Release from this machine (builds Windows + Android, creates a
clean Windows zip, tags `vX.Y.Z`, and uploads both assets):

```powershell
.\tools\publish_github_release.ps1 -Version 1.0.0
```

Use `-SkipBuild` to reuse existing build outputs, or `-Draft` for a draft
Release. Do not zip `release/windows/tomato_english_happy_talking/` directly;
the publish script stages a clean package under `release/dist/`.

Run Web UI tests:

```powershell
npm --prefix web_ui test
```

Run Flutter analysis:

```powershell
cd app
flutter analyze
```

## Build Scripts

### `tools/build_windows.ps1`

- Builds the bundled Web UI before the Flutter build.
- Supports Debug, Release, and optional `-Run`.
- Copies the runnable Windows app to `release/windows/tomato_english_happy_talking/`.
- Keeps runtime data in that local release directory during development.

### `tools/build_android.ps1`

- Builds an Android release APK.
- Copies the APK to `release/android/`.
- Can run Android Debug/Release on a connected device or emulator when invoked
  with the relevant flags.

### `tools/publish_github_release.ps1`

- Builds Windows Release and Android Release APK (unless `-SkipBuild`).
- Stages a clean Windows zip from `app/build/windows/x64/runner/Release` plus
  FFmpeg into `release/dist/`, excluding local runtime data and secrets.
- Copies a versioned APK into `release/dist/`.
- Creates annotated tag `vX.Y.Z`, pushes it, and runs `gh release create` with
  both assets.

Cold Android release builds may take more than 15 minutes while Gradle,
Flutter plugins, R8, resources, and mapping outputs initialize. Give automated
builds a wider timeout, especially on a clean machine.

## Release And Data Safety

The local Windows release directory is also a development runtime directory. It
may contain logs, diagnostics, databases, API cache, exported videos, imported
songs, generated audio, and old local configuration files.

For public distribution, do not zip that directory directly. Create a clean
staging folder containing only the executable, DLLs, Flutter `data/` assets,
FFmpeg, and required runtime files. Exclude at least:

- `logs/`
- `diagnostics/`
- `recording-export/`
- `suno-music/`
- API cache directories
- SQLite databases
- `security/`
- settings files
- any API key or token material

## Development Notes

- App feature work should keep Flutter services separate from UI state.
- Web UI must communicate with Flutter through the typed bridge protocol.
- Cloud calls should prefer local parsing, local cache, and saved business data
  before making new paid requests.
- Successful remote results may be cached; API keys, failed responses, mock
  fallbacks, and diagnostics with sensitive data must not be cached as reusable
  content.
- The default product model is a book/chapter learning workspace, not a game
  lobby or reward system.

More implementation details live under [docs/](docs/), especially the change
log, migration notes, prompt-review notes, and release/build troubleshooting
documents.

## License

Apache License 2.0. See [LICENSE](LICENSE).
