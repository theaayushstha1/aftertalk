# Aftertalk — Product Requirements Document

**Status**: frozen as of 2026-04-26 (day 0). Changes require an ADR in `~/Documents/Aftertalk/20 — Decisions/`.

## 1. Product summary
A fully on-device iOS app that turns spoken meetings into structured notes and a voice-driven Q&A interface. Users record a meeting in airplane mode, the app transcribes locally, generates a structured summary (decisions, action items with owners, topics, open questions), and exposes a hold-to-talk Q&A loop scoped per-meeting or across all meetings. Nothing leaves the device.

## 2. Target user (single persona, single use case)
A founder, PM, or researcher who attends 5–15 meetings/week, takes notes inconsistently, doesn't want their conversations sent to an AI vendor's servers. They are willing to opt in to airplane mode for the duration of a meeting in exchange for a privacy guarantee that's verifiable, not just claimed.

## 3. Core functional requirements (must-have for submission)
| ID | Requirement | Source |
|---|---|---|
| F1 | Capture audio via AVAudioEngine on iPhone hardware in airplane mode | Brief |
| F2 | Transcribe streaming audio fully on-device using a non-Apple ASR (Moonshine preferred) | Brief |
| F3 | After recording stops, generate a structured summary with: decisions, action items (with owners where attributable), topics covered, open questions | Brief |
| F4 | Speech-in / speech-out Q&A loop scoped to the just-recorded meeting | Brief |
| F5 | First spoken word of answer arrives in <3s on iPhone 14+ | Brief |
| F6 | All processing on-device — no network requests in production code path | Brief |
| F7 | Speaker labels surface in transcript and in Q&A answers | Brief |
| F8 | Privacy claim is verifiable: `NWPathMonitor` assertion + source-grep proof in README | Self-imposed |

## 4. Stretch requirements (all five shipped + extras)
| ID | Stretch | Status |
|---|---|---|
| S1 | Speaker diarization (Pyannote Core ML via FluidAudio) | shipped day 4 |
| S2 | Streaming Q&A (sentence-boundary chunking → Kokoro TTS) | shipped day 4 |
| S3 | Cross-meeting memory (hierarchical 3-layer RAG, global chat thread) | shipped day 5 |
| S4 | Neural TTS (Kokoro 82M ANE-optimized) | shipped day 4 |
| S5 | Power profile via MetricKit (30-min meeting + 10-min Q&A) | shipped day 6 |
| S6 (bonus) | Senior-grade VAD + barge-in (TEN-VAD + SmartTurnV3 EoU) | shipped day 5 |
| S7 (bonus) | Per-meeting + global chat threads with citations | shipped day 5 |

## 5. Non-functional requirements
| ID | Req | Target |
|---|---|---|
| NF1 | Time-to-first-spoken-word (TTFSW) | <1.5s on 17 Pro Max, <3s on Air |
| NF2 | ASR TTFT (first transcript token) | <250ms |
| NF3 | Summary generation latency for 30-min meeting | <8s |
| NF4 | Memory peak during 30-min recording + 10-min Q&A | <800MB |
| NF5 | Battery delta for full 40-min session | <12% on 100% start |
| NF6 | Thermal state | stays in `.fair` or below |
| NF7 | Cold-start to ready-to-record | <3s |
| NF8 | Public OSS repo with MIT license, build instructions, demo video | yes |

## 6. Acceptance criteria (run on day 7 before submission)
- [ ] Airplane mode toggled ON; full demo flow completes (record → summary → Q&A → cross-meeting Q&A) without errors.
- [ ] `git grep -i "URLSession\|URLRequest\|http://\|https://"` returns zero matches in `Aftertalk/` source (excluding comments and README).
- [ ] Demo video shows Control Center with airplane indicator visible throughout.
- [ ] All 5 stretch goals demonstrated in the video.
- [ ] Perf chart in `perf/` shows TTFSW, memory, thermal, battery.
- [ ] README hero gif renders in GitHub.
- [ ] Submission email sent to Nirbhay with repo link + video link.

## 7. Out of scope (for this take-home)
- Android.
- macOS Catalyst build.
- Cloud sync between devices.
- Calendar integration.
- Real-time live translation.
- Custom vocabulary / domain adaptation.
- Multi-user accounts / login.
- App Store distribution (TestFlight ad-hoc only if anyone asks).
- iOS Widget / Live Activity.
- watchOS companion.
- Any feature requiring Apple Speech (`SFSpeechRecognizer`) — brief explicitly discourages.

## 8. Privacy claim audit (referenced in README)
1. **Static**: `git grep` proof that no networking APIs are imported in production paths.
2. **Runtime**: `NWPathMonitor` assertion in `AppDelegate` that fails fast if any interface is up while a meeting is recording. Logged + visible in debug overlay.
3. **Visual**: airplane mode badge in app chrome shows green only when all interfaces are down.
4. **Audit**: README links to specific commit SHAs that introduced each privacy invariant.

## 9. Brief-to-feature traceability
Every line of the AirCaps PDF brief maps to a feature ID above. See `docs/brief-traceability.md` for the line-by-line cross-walk (created day 0).

## 10. UX surfaces (high-level)
1. **Onboarding** (3 screens): privacy promise, airplane mode prompt, microphone permission.
2. **Meetings list**: cards with title, date, duration, speaker count, summary preview.
3. **Meeting detail**: tabs for Transcript (with speaker labels), Summary (4 sections), Chat thread.
4. **Global chat**: cross-meeting Q&A in a single conversation thread.
5. **Settings**: airplane mode status, model storage usage, "Questions I struggled with" log.

## 11. What "done" looks like
A reviewer at AirCaps clones the repo, opens it in Xcode, builds to an iPhone 14+, toggles airplane mode, hits record, talks for 5 minutes, stops, sees a structured summary, asks a voice question, gets a voice answer in under 3 seconds — all without ever wondering "is this actually offline." The privacy claim is provable, the UX feels finished, and the perf numbers in the README hold up to a stopwatch.
