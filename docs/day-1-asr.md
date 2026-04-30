> **Archived planning log.** This was a daily brief written before the work shipped. Some component picks (gte-small, sqlite-vec, target latency numbers) were superseded by the actual implementation. For the current architecture see [README.md](../README.md), [DECISIONS.md](../DECISIONS.md), and [THOUGHT-PROCESS.md](../THOUGHT-PROCESS.md).

---

# Day 1 — Audio capture + Moonshine streaming ASR (Mon Apr 27)

## What you're building today
Live mic capture via AVAudioEngine on a real iPhone, streaming into Moonshine ASR. By end of day, you talk into the phone and a debug overlay shows transcript words appearing as you speak, with first-token latency under 250ms.

## Worktree
- Path: `~/Desktop/Aircaps/` (main branch — this is foundational, no fork yet)
- Branch: `main`

## Pre-flight checks
- [ ] Xcode 16+ installed (asked yesterday, verify before starting)
- [ ] iPhone Air or iPhone 17 Pro Max paired in Xcode for run-on-device
- [ ] Apple Developer account is on the Xcode signing team
- [ ] `~/Desktop/Aircaps/` has CLAUDE.md, PRD.md, ARCHITECTURE.md committed
- [ ] Foundation Models entitlement verified (build a "hello world" Foundation Models call to confirm region availability)

## Files this day touches
- **NEW** `Aftertalk.xcodeproj` — created in step 1
- **NEW** `Aftertalk/App/AftertalkApp.swift` — `@main` entry point
- **NEW** `Aftertalk/App/RootView.swift` — placeholder tab bar with Record button
- **NEW** `Aftertalk/Recording/AudioCaptureService.swift` — AVAudioEngine wrapper
- **NEW** `Aftertalk/Recording/MoonshineStreamer.swift` — Moonshine integration
- **NEW** `Aftertalk/Recording/RecordingViewModel.swift` — state for record button + live transcript
- **NEW** `Aftertalk/TTS/AudioSessionManager.swift` — `.playAndRecord` + `.voiceChat` config
- **NEW** `Aftertalk/Profiling/PerfMonitor.swift` — timestamp logger for TTFT
- **NEW** `Info.plist` — `NSMicrophoneUsageDescription`, `UIBackgroundModes` (audio)

## Dependencies to add
- **SPM**: `https://github.com/moonshine-ai/moonshine-swift.git` (latest)
- **Bundled**: Moonshine-tiny English model `moonshine-tiny-en.onnx` placed in Xcode asset bundle (download from Moonshine's GitHub release page)

## Implementation order
1. **Xcode project bootstrap** (~30 min)
   - Create `Aftertalk.xcodeproj`, iOS 18+ target, Swift 6 strict concurrency, bundle ID `com.theaayushstha.aftertalk`.
   - Add SPM dependency for `moonshine-swift`.
   - Add `NSMicrophoneUsageDescription` to Info.plist with copy: "Aftertalk records meetings on-device. Audio never leaves your phone."
   - Run on simulator first (build sanity), then on iPhone.
2. **Audio session setup** (`AudioSessionManager`)
   - Order: `.playAndRecord` → `.voiceChat` → `setPrefersEchoCancelledInput(true)` → activate.
   - Register interruption observer.
3. **AVAudioEngine capture** (`AudioCaptureService`)
   - VoiceProcessingIO audio unit (not raw mic) for built-in AEC.
   - 48kHz mic → AVAudioConverter → 16kHz PCM float32 buffers (Moonshine input format).
   - Emit buffers via an `AsyncStream<AVAudioPCMBuffer>`.
4. **Moonshine streaming wrapper** (`MoonshineStreamer`)
   - Wrap `moonshine-swift`'s streaming API.
   - Consume the `AsyncStream` from `AudioCaptureService`.
   - Emit `TranscriptDelta` events to a downstream actor.
5. **Record button UI** (`RootView` + `RecordingViewModel`)
   - Big red circular button. Tap to start, tap again to stop.
   - Live transcript text under the button, updating word-by-word.
6. **Debug overlay** showing TTFT (time from speech onset to first word) and current ASR confidence. Toggle via 3-finger tap.
7. **Build to device, talk into it.** Verify words appear under 250ms.

## Verification
- [ ] Build to iPhone Air or 17 Pro Max with no warnings (Swift 6 strict concurrency clean).
- [ ] Tap record, say "the quick brown fox jumps over the lazy dog" — full sentence transcribed within 1s of finishing.
- [ ] Debug overlay shows TTFT < 250ms (first word appears within 250ms of speech start).
- [ ] Toggle airplane mode ON. Re-record. Same result. (No network dependency.)
- [ ] `git grep -i "URLSession\|URLRequest\|http" Aftertalk/` returns zero matches.
- [ ] Background/lock the phone mid-recording — recording continues thanks to `UIBackgroundModes: audio`.
- [ ] Receive a phone call mid-recording — `AVAudioSession.interruptionNotification` fires, recording pauses, resumes after call.

## Email home plate (4 bullets for Aayush to forward to Nirbhay)
- Audio capture + Moonshine streaming ASR live on iPhone (Air + 17 Pro Max tested).
- Time-to-first-token measured at <Xms> (target was 250ms).
- Airplane mode flight tested — full pipeline works with all radios off.
- Tomorrow: structured summary via Apple Foundation Models + chunk + embedding pipeline.

## Demo prep
Quick screen recording of: tap record → "this is a test of Aftertalk" → words appear live → tap stop. Save to `~/Documents/Aftertalk/attachments/2026-04-27-asr-demo.mov` for later use in final video.

## If you get stuck
- **Moonshine SPM integration fails**: clone `moonshine-swift` locally and use a local SPM package reference. The `examples/ios/Transcriber` directory has a working integration.
- **AVAudioEngine returns garbage data after first stop/restart**: re-initialize the engine on each recording session rather than reusing.
- **`.voiceChat` mode causes unexpected ducking**: that's normal; we want it for AEC. Don't switch to `.measurement` (kills AEC).
- **TTFT > 250ms on Air**: try Moonshine-tiny instead of Moonshine-base; it's 4x smaller.

## End-of-day tasks
- [ ] Commit: `feat(asr): wire Moonshine streaming ASR with AVAudioEngine capture`
- [ ] Push to `main`.
- [ ] Append to `~/Documents/Aftertalk/10 — Daily Logs/2026-04-27 — Day 1.md`.
- [ ] If a decision was made, add ADR to `~/Documents/Aftertalk/20 — Decisions/`.
- [ ] Send email home plate to Aayush.
