# Volcengine Migration Plan

## Context

This document records the confirmed migration direction for replacing the current legacy Volcengine TTS integration with the newer Doubao TTS 2.0 API, and tracks adjacent impact on AI chat and pronunciation scoring.

## Confirmed Decisions

- Do not hardcode any production API key in source code.
- Continue storing all cloud credentials in `AppConfig` via `flutter_secure_storage`.
- Replace the current legacy TTS endpoint `https://openspeech.bytedance.com/api/v1/tts` with the V3 unidirectional HTTP Chunked endpoint `https://openspeech.bytedance.com/api/v3/tts/unidirectional`.
- Use new-console authentication for TTS 2.0 with:
  - `X-Api-Key`
  - `X-Api-Resource-Id: seed-tts-2.0`
  - optional `X-Api-Request-Id`
- Prefer HTTP Chunked over bidirectional WebSocket for this app because the current Flutter flow is request once, receive audio, then play it locally.

  ## Status Update (2026-05)

  - Doubao TTS 2.0 playback migration is complete and remains on HTTP Chunked.
  - Realtime chat is no longer a plan item only: `RealtimeVoiceService` now speaks the official V3 binary WebSocket protocol.
  - Realtime authentication prefers API-key mode (`X-Api-Key`) and falls back to legacy `App ID + Access Key + App Key` only when API-key mode fails and `App ID` is available.
  - `AppConfig.volcRealtimeApiKey` and `AppConfig.volcBigAsrApiKey` both support unified-key fallback to `AppConfig.volcTtsApiKey`.
  - Chat and follow-read now share sentence playback states (`idle`, `waitingStart`, `playing`, `success`, `failed`) and a unified replay / failure / ellipsis UI.
  - On Windows, playback start / completion is now inferred from actual playback position progression instead of trusting `just_audio_windows` state transitions alone.

## Credential Record

- This document records the required credential fields and attachment points only.
- Do not place any real API key value in this repository or in this document.
- Real secrets must stay in `flutter_secure_storage` and, if needed for backup, in the team's private password manager outside the repo.

### Implemented local bootstrap path

- The app now calls `AppConfig.seedSecureStorageFromEnvironment()` during startup.
- This bootstrap reads compile-time `--dart-define` values and writes any non-empty secret to `FlutterSecureStorage`.
- The write path is local-machine only and is meant as a transitional no-backend solution.
- This avoids committing real API keys to the repository, but it does not make an app-owned key safe for public distribution.

### Supported bootstrap keys

- Legacy TTS:
  - `TOMATO_VOLC_TTS_APP_ID`
  - `TOMATO_VOLC_TTS_TOKEN`
  - `TOMATO_VOLC_ACCESS_KEY`
  - `TOMATO_VOLC_SECRET_KEY`
- Doubao TTS 2.0:
  - `TOMATO_VOLC_TTS_API_KEY`
  - `TOMATO_VOLC_TTS_RESOURCE_ID`
  - `TOMATO_VOLC_TTS_SPEAKER_ID`
- Realtime voice:
  - `TOMATO_VOLC_REALTIME_APP_ID`
  - `TOMATO_VOLC_REALTIME_API_KEY`
- BigASR:
  - `TOMATO_VOLC_BIGASR_API_KEY`
- Realtime / BigASR dedicated keys are optional in the current code path; if omitted, both services fall back to `TOMATO_VOLC_TTS_API_KEY`.

### Runtime usage contract

- Services must read secrets only from `AppConfig`.
- Services must not read secrets directly from UI fields, local JSON files, or plain SQLite tables.
- Do not log raw keys, request headers, or full authorization objects.
- If a key is missing, surface a configuration error or fallback behavior, but do not print the secret source.

### Recommended next-step refactor

- Keep this bootstrap path as a local transitional solution.
- For TTS 2.0 / realtime voice / BigASR, migrate service calls to API-key-based `AppConfig` getters instead of legacy token-based fields.
- Root PowerShell scripts now support `-DartDefine` passthrough for Windows debug, Android debug, and Android release workflows.
- If a future local workflow needs less command-line exposure, consider adding a local-only bootstrap helper that writes secure storage without embedding long-lived secrets into a distributable build.

### Required credential fields for the current migration

- Doubao TTS 2.0
  - header: `X-Api-Key`
  - header: `X-Api-Resource-Id`
  - planned default value: `seed-tts-2.0`
  - optional header: `X-Api-Request-Id`
- Realtime voice chat
  - preferred header: `X-Api-Key`
  - fallback legacy headers: `X-Api-App-ID`, `X-Api-Access-Key`, `X-Api-App-Key`
  - required resource header: `X-Api-Resource-Id: volc.speech.dialog`
- BigASR recognition
  - dedicated API key recommended for production separation
  - current runtime may reuse the TTS API key for local development convenience

### Required credential fields for the preferred target architecture

- Realtime voice chat
  - keep a dedicated Volcengine realtime voice API key field in secure storage
  - keep any model / app / resource identifier field separate from the TTS resource id if the final API contract requires it
- BigASR-based follow-read evaluation
  - keep a dedicated ASR API key field in secure storage if the selected BigASR endpoint does not share the TTS credential scope
  - do not assume the TTS `seed-tts-2.0` resource id is reusable for ASR

## Why HTTP Chunked Still Fits Follow-Read Playback

- The app currently synthesizes one sentence or one AI reply at a time for local playback.
- The current code path already expects a single service call that returns playable audio bytes.
- `dio` can keep the existing service-layer architecture with streamed HTTP responses.
- Realtime chat now uses the separate V3 binary WebSocket protocol; HTTP Chunked remains the correct transport for TTS playback.

## Current Code Affected

- `app/lib/services/tts_service.dart`
- `app/lib/core/config/app_config.dart`
- `app/lib/features/profile/profile_screen.dart`
- `app/lib/features/follow_read/providers/follow_read_provider.dart`
- `app/lib/features/chat/providers/chat_provider.dart`

## Planned TTS Refactor

### 1. Configuration model

- Remove reliance on legacy TTS `App ID + Token` for the main synthesis flow.
- Add secure storage fields for:
  - TTS API Key
  - TTS Resource Id
  - default Speaker ID
- Keep configuration user-editable in the settings page.

### 2. TTS service rewrite

- Parse chunked JSON responses from the V3 endpoint.
- Collect each response chunk whose `data` field contains base64 audio.
- Decode and append audio bytes in order.
- Stop on final success packet with `code = 20000000`.
- Surface server errors instead of failing silently.

### 3. Voice model update

- Replace legacy speaker IDs like `en_us_09` and `en_uk_01`.
- Use speaker IDs that are valid for `seed-tts-2.0`.
- Rebuild the voice list only after confirming the exact English-capable TTS 2.0 speakers from the official speaker catalog.

### 4. UI impact

- Update the profile/settings page labels from legacy `App ID / Token` terminology to `API Key / Resource ID / Speaker`.
- Keep follow-read and chat playback flows unchanged at the provider level unless the new API requires richer options.

## Validation Plan

- Verify one sentence playback in follow-read mode.
- Verify one AI reply playback in chat mode.
- Confirm error messages for:
  - missing API key
  - invalid resource id
  - invalid speaker
  - quota / permission failure
- Confirm generated audio is playable on both Windows and Android.

## Concrete Code Refactor Checklist

### Phase 1: complete Doubao TTS 2.0 migration for playback

- `app/lib/core/config/app_config.dart`
  - add secure storage getters and setters for `ttsApiKey`, `ttsResourceId`, and `ttsSpeakerId`
  - keep legacy fields only if a temporary compatibility path is still needed during migration
- `app/lib/features/profile/profile_screen.dart`
  - replace legacy TTS `App ID / Token` form fields with `API Key / Resource ID / Speaker`
  - add validation copy for missing key, missing resource id, and empty speaker id
- `app/lib/services/tts_service.dart`
  - switch base endpoint to `api/v3/tts/unidirectional`
  - send `X-Api-Key` and `X-Api-Resource-Id` headers
  - parse chunked JSON frames and append base64 audio payloads in order
  - raise explicit errors on non-success terminal frames or empty audio
- `app/lib/features/follow_read/providers/follow_read_provider.dart`
  - keep provider behavior stable, but ensure TTS exceptions surface clearly to UI state
- `app/lib/features/chat/providers/chat_provider.dart`
  - keep current staged playback path working with the new TTS service until realtime chat rewrite starts

### Phase 2: split STT from pronunciation scoring before chat rewrite

- `app/lib/services/scoring_service.dart`
  - stop growing chat-mode STT responsibilities inside the pronunciation scoring service
  - isolate follow-read assessment contract from generic speech recognition helpers
- `app/lib/services/`
  - introduce a dedicated speech recognition service for chat-mode STT if staged chat remains temporarily
- `app/lib/features/chat/providers/chat_provider.dart`
  - rewire chat STT calls to the dedicated speech recognition service instead of `ScoringService`

### Phase 3: implemented realtime voice chat architecture

- **Status: Complete**

- `app/lib/services/`
  - add a realtime voice client service responsible for WebSocket session lifecycle, auth headers, event serialization, and binary/audio frame handling
- `app/lib/features/chat/providers/chat_provider.dart`
  - replace one-shot record -> STT -> AI -> TTS sequencing with session state management
  - handle microphone streaming, partial ASR updates, assistant turn events, interruption, and streamed playback state
- `app/lib/shared/` or `app/lib/features/chat/`
  - add typed models for realtime events such as ASR updates, response segments, session status, and playback chunks
- `app/lib/services/ai_service.dart`
  - keep only text-mode fallback responsibilities if still needed; do not keep it as the primary voice dialogue path
- `app/lib/services/tts_service.dart`
  - keep follow-read / non-chat playback responsibilities only once realtime voice owns chat audio output

### Phase 4: redesign follow-read evaluation if Azure is to be removed

- **Status: Complete**
- `RecognitionBasedAssessmentEngine` now provides recognition-driven scoring without Azure dependency.
- Scoring model is heuristic-based (text matching, coverage, fluency proxies).
- All follow-read evaluation runs locally after BigASR recognition; no Azure pricing or latency.
- Database schema extended with nullable fields (`token_scores_json`, `evaluation_meta_json`) for future rich scoring data.
- Follow-read provider updated to use new engine via interface injection pattern.


### Phase 5: validation and rollout

- add focused service-level tests for recognition-based scoring heuristics
- run Windows follow-read playback and scoring validation after TTS + recognition migration
- run chat-mode smoke validation before and after realtime rewrite
- confirm Android playback and recognition still works after all service refactors
- confirm settings migration does not orphan previously saved non-TTS credentials

## Open Questions

- Which official English speakers are available and appropriate for `seed-tts-2.0` in this app.
- Whether AI chat should later expose server-side audio output instead of continuing to synthesize reply text locally through TTS 2.0.
- How much additional Windows / Android smoke coverage is needed around first-play reliability after the new playback-progress-based completion logic.

## AI Chat Impact Assessment

### Current chat chain

- The current voice chat flow now centers on realtime dialogue with a staged voice input fallback:
  - microphone recording
  - BigASR streaming recognition
  - realtime dialogue response
  - TTS playback for non-realtime follow-read tasks
- In code terms, the current primary chat path is:
  - `StreamingAsrService` for chat-mode STT
  - `RealtimeVoiceService` for dialogue orchestration
  - `TtsService` for follow-read and non-chat synthesis playback

### Current migration baseline

- Doubao TTS 2.0 migration is complete for playback responsibilities.
- `chat_provider.dart` has moved away from Ark text completion and uses realtime dialogue + BigASR recognition.
- For the current product shape, chat and follow-read now split responsibilities as:
  - realtime dialogue events and session lifecycle in `RealtimeVoiceService`
  - chat STT in `StreamingAsrService`
  - follow-read/non-chat synthesis in `TtsService`

### Recommended adjacent cleanup

- Follow-read scoring has now been migrated to `RecognitionBasedAssessmentEngine`, which uses BigASR for recognition and computes heuristic scores:
  - **Accuracy**: matched word count / total words in reference
  - **Completeness**: same as accuracy (coverage of reference)
  - **Fluency**: penalty-based on recognition length ratio to reference length
  - **Prosody**: placeholder (same as fluency for now)
  - **Overall**: average of accuracy, completeness, fluency
  - **Per-word scores**: 90 for matched, 40 for omitted words
- `ScoringService` is now deprecated for follow-read use; `RecognitionBasedAssessmentEngine` is the primary follow-read assessment engine.
- The legacy Azure-based `AzureSpeechAssessmentEngine` is kept for fallback/testing but no longer drives follow-read UI.

### Follow-Read Scoring Architecture

- `app/lib/services/recognition_based_assessment_service.dart` implements the new engine.
- Scoring logic uses Longest Common Subsequence (LCS) algorithm to match spoken words with reference text.
- No external pronunciation assessment service is required; all scoring is heuristic and local-compute-based.
- This allows follow-read to work offline (except for audio synthesis and recognition, which still require cloud TTS and BigASR services).

### Future architecture option: realtime voice model

- Volcengine also provides a separate end-to-end realtime voice model API for voice-native chat.
- That API officially supports:
  - speech-to-speech interaction
  - text query input
  - server-side ASR + chat + TTS streaming
  - system prompt style control (`bot_name`, `system_role`, `speaking_style`) or `character_manifest`
  - external RAG / web-agent style extensions
- This is not a drop-in replacement for the current Flutter architecture.
- Adopting it would mean building a new WebSocket session-based voice chat stack with:
  - streaming microphone upload
  - streaming audio playback
  - interruption handling
  - realtime session state and conversation sync
- Conclusion: for the current app, do not treat realtime voice as a small TTS-side migration. Treat it as a separate chat architecture refactor that can be chosen when voice-native dialogue becomes the target product shape.

## Updated Direction Based On Latest Review

- If the product goal is a truly voice-native AI conversation experience, the preferred direction is now:
  - AI dialogue: migrate from the staged chat pipeline to the end-to-end realtime voice model
  - follow-read scoring: keep the dedicated follow-read flow, but evaluate BigASR as a recognition-and-metadata engine rather than assuming it is a drop-in pronunciation scoring API

## Realtime Voice Model For Dialogue

### Why it fits chat better than the staged pipeline

- The current chat implementation is a stitched flow of:
  - local recording
  - STT
  - text LLM chat
  - TTS playback
- The realtime voice model already exposes this as one session-oriented voice interaction protocol with server-side:
  - ASR events
  - chat response events
  - TTS audio events
  - interruption events
  - context management events
- For a conversational mode, this is a better product fit than continuing to manually glue `ScoringService`, `AiService`, and `TtsService` together.

### Key documented capabilities

- WebSocket-only connection model.
- Supports audio input, text input, and audio-file style streamed input.
- Supports `push_to_talk`, `keep_alive`, `text`, and `audio_file` input modes.
- Supports text query events (`ChatTextQuery`) in addition to microphone audio.
- Supports output audio streaming through `TTSResponse` events.
- Supports interruption and turn control through:
  - `ASRInfo`
  - `ASRResponse`
  - `ASREnded`
  - `ClientInterrupt`
- Supports conversation state management through create / update / retrieve / truncate / delete events.
- Supports prompt / persona control:
  - O / O2.0 versions: `bot_name`, `system_role`, `speaking_style`
  - SC / SC2.0 versions: `character_manifest`
- Supports external RAG and web-agent style extensions.

### Important constraints for this app

- This is not an HTTP request-response API; it requires a persistent WebSocket session manager.
- The client must handle binary protocol frames, session IDs, event routing, and streaming audio playback.
- The current Flutter chat code would need a real rewrite, not a service swap.
- Current documented client audio expectations are still streaming-oriented:
  - microphone input or file input forwarded in small audio packets
  - server-side VAD / session lifecycle handling
- The app will need a dedicated realtime chat layer, likely replacing most of the current chat provider internals.

### Concrete code impact if adopted

- `app/lib/services/ai_service.dart`
  - can no longer remain the primary dialogue engine for voice chat mode
  - text-completions mode may still be kept as a fallback or text-only mode
- `app/lib/features/chat/providers/chat_provider.dart`
  - should be redesigned around websocket session lifecycle instead of one-shot REST calls
  - should consume streaming ASR / chat / TTS events rather than polling local state transitions only
- `app/lib/services/tts_service.dart`
  - is no longer the chat-mode playback source if realtime voice is adopted for dialogue
  - can still remain for follow-read sentence playback and non-chat synthesis tasks

### Current recommendation

- For chat mode specifically, keep the realtime voice model as the primary architecture and continue hardening protocol/session behavior.
- Treat follow-read as an independent track focused on scoring model evolution, separate from chat realtime lifecycle changes.

## Pronunciation Scoring Assessment

### Current Azure capability in this app

- The current follow-read scoring depends on Azure Pronunciation Assessment.
- The app currently consumes the following scoring outputs:
  - overall score
  - accuracy score
  - fluency score
  - completeness score
  - prosody score
  - per-word score and error type

### What current Volcengine docs do document

- In the official Volcengine speech docs reviewed during this research, the speech side currently documents:
  - ASR transcription
  - word / utterance timestamps
  - speech rate metadata
  - volume metadata
  - emotion detection
  - gender detection
  - speaker separation
  - hotword / context / RAG-assisted recognition improvements

### What is missing for a true replacement

- None of the reviewed public Volcengine docs describe a dedicated pronunciation assessment API equivalent to Azure's current capability.
- No reviewed page documents:
  - reference-text-based pronunciation scoring
  - per-word miscue categories such as omission / insertion / mispronunciation
  - fluency / completeness / prosody scoring aligned to a learner's target sentence
- ASR-side metadata such as speech rate, volume, or emotion is useful, but it is not a substitute for language-learning pronunciation evaluation.

## BigASR For Follow-Read Scoring

### What BigASR can realistically provide

- BigASR can return enough structure to support a custom scoring pipeline based on recognition results and timing signals:
  - recognized text
  - utterance segmentation
  - word / character timestamps
  - speech-rate metadata
  - volume metadata
  - optional emotion / gender / language metadata
- For this app, the most compatible documented integration path is the streaming or streamed-input WebSocket ASR interface, because it accepts local audio bytes directly.

### What does not fit well

- The async recording-file recognition API (`auc`) expects an audio URL submission flow.
- This app is a local Flutter client without a backend upload service, so `auc` is a poor near-term fit unless a file hosting layer is added.
- That means the practical no-backend option is BigASR websocket input, not URL-based file recognition.

### What BigASR cannot provide out of the box

- BigASR does not currently return the same learner-oriented score structure used by `PronunciationResult`:
  - no direct overall pronunciation score
  - no direct accuracy / fluency / completeness / prosody bundle
  - no direct omission / insertion / mispronunciation labeling against a reference sentence

### Viable replacement path if self-built scoring is acceptable

- If you accept a custom heuristic scoring system instead of Azure-equivalent pronunciation assessment, BigASR can still be used as the foundation.
- A practical self-built scoring approach would likely be:
  - accuracy proxy: compare recognized text against the target sentence with alignment or edit-distance logic
  - completeness proxy: measure how much of the reference sentence was covered
  - fluency proxy: derive from pause patterns, segmentation, and speech-rate stability
  - volume / rhythm hints: derive from returned metadata where available
- Prosody-like evaluation would still be limited compared with Azure's dedicated pronunciation assessment.

### Current recommendation

- If the requirement is strict parity with the current scoring UX in follow-read, BigASR alone is not enough.
- If the requirement is to remove Azure and accept a new scoring model, then BigASR can be used to build:
  - text-match scoring
  - timing-based fluency heuristics
  - lightweight feedback on pace / pauses / coverage
- In that case, the app should rename the feature conceptually from "Azure-style pronunciation assessment" to "recognition-based reading evaluation".

### Current conclusion

- Migration complete: the app now operates with:
  - chat mode: end-to-end realtime voice model with BigASR recognition
  - follow-read playback: Doubao TTS 2.0
  - follow-read scoring: BigASR-driven `RecognitionBasedAssessmentEngine` (no Azure dependency)
- The recognition-based scoring model computes accuracy, completeness, fluency, and prosody heuristics based on word-level matching via LCS algorithm.
- This approach removes Azure dependency for follow-read and allows offline scoring (except TTS synthesis and speech recognition, which remain cloud services).
- Future improvements can extend the scoring model to include timing-based metrics and prosody analysis as BigASR provides richer metadata.


## Official Sources Reviewed In This Round

- Doubao TTS V3 WebSocket bidirectional docs
- Doubao TTS V3 HTTP Chunked / SSE unidirectional docs
- Doubao speech synthesis product overview and product updates
- Doubao speech recognition product overview
- BigASR streaming speech recognition API docs
- Realtime voice model experience-center docs
- Doubao end-to-end realtime voice model API docs

## Research Notes So Far

- V3 bidirectional WebSocket TTS supports `X-Api-Key` with `X-Api-Resource-Id: seed-tts-2.0`.
- V3 HTTP Chunked/SSE unidirectional TTS also supports `X-Api-Key` with `X-Api-Resource-Id: seed-tts-2.0`.
- HTTP Chunked returns JSON chunks whose `data` field contains base64 audio payloads.
- The final success frame returns `code = 20000000`.
- BigASR currently documents transcription, timestamps, speech-rate / volume / emotion / gender metadata, but not learner-oriented pronunciation scoring.
- The end-to-end realtime voice model is a separate WebSocket architecture suitable for future low-latency voice chat, not a drop-in patch for the current app.
- Realtime voice is now a viable target architecture for chat mode if the app intentionally moves to a voice-native websocket dialogue stack.
- BigASR websocket integration is a better fit than URL-based AUC for a no-backend Flutter client, but it supports custom scoring only, not current Azure-equivalent pronunciation assessment.