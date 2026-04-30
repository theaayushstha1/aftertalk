> **Archived planning log.** This was a daily brief written before the work shipped. Some component picks (gte-small, sqlite-vec, target latency numbers) were superseded by the actual implementation. For the current architecture see [README.md](../README.md), [DECISIONS.md](../DECISIONS.md), and [THOUGHT-PROCESS.md](../THOUGHT-PROCESS.md).

---

# AirCaps Brief → Aftertalk Feature Traceability

Every requirement and constraint from the AirCaps take-home PDF maps to a feature ID in `PRD.md`. This file is the audit trail.

## Required capabilities
| Brief line | Feature ID | Notes |
|---|---|---|
| "Captures audio via AVAudioEngine on a real iPhone (14+) in airplane mode" | F1 | `AudioCaptureService` + `AirplaneModeCheck` |
| "Transcribes streaming audio fully on-device (Moonshine preferred, WhisperKit acceptable, NOT Apple Speech)" | F2 | `MoonshineStreamer`; WhisperKit ready as fallback behind `ASRService` protocol |
| "Generates a structured post-meeting summary: decisions, action items (with owners where attributable), topics covered, open questions" | F3 | `MeetingSummary` `@Generable` struct + `SummaryGenerator` |
| "Speech-in / speech-out Q&A loop scoped to the recorded meeting" | F4 | `QAOrchestrator` + `ChatThreadView` |
| "First spoken word arrives in <3s on iPhone 14+" | F5, NF1 | Measured via `PerfMonitor`, displayed in debug overlay |
| "All processing on-device — no network requests in production code path" | F6, F8 | Static (`git grep`) + runtime (`NWPathMonitor`) + visual (badge) audit |
| "Speaker labels in transcript and Q&A answers" | F7 | `DiarizationService` + speaker-aware system prompt |
| "Streaming-vs-chunked ASR — choice should be justified" | (README) | One-paragraph justification: streaming for live-feel + retrieval prep |

## Constraints
| Brief line | Feature ID / Action | Notes |
|---|---|---|
| "Fully on-device — any cloud is disqualifying" | F6 + audit | Three-layer audit (static/runtime/visual) |
| "iOS only" | (project) | iOS 18+ target, no Catalyst |
| "~1 week" | (schedule) | 7-day sprint, 8-10 hrs/day |
| "Open-source models welcomed" | (architecture) | Moonshine, Kokoro, Pyannote, gte-small, TEN-VAD, SmartTurnV3 — all OSS |

## Stretch goals (all five shipped)
| Brief line | Feature ID | Notes |
|---|---|---|
| "Speaker diarization" | S1 | FluidAudio Pyannote Core ML |
| "Streaming Q&A" | S2 | Sentence-boundary chunking → Kokoro TTS prefetch |
| "Cross-meeting memory" | S3 | Hierarchical 3-layer RAG, global chat thread |
| "Neural TTS" | S4 | FluidAudio Kokoro 82M ANE-optimized |
| "Power profiling" | S5 | MetricKit + matplotlib chart in `perf/` |

## Bonus stretches (over-delivery)
| Bonus | Feature ID | Why |
|---|---|---|
| Senior-grade VAD + barge-in | S6 | TEN-VAD + SmartTurnV3 gives Gemini-Live-grade conversational latency |
| Per-meeting + global chat threads with citations | S7 | Goes beyond "scoped to recorded meeting" — adds cross-meeting Q&A as a separate UX surface |

## Submission requirements
| Brief line | Action |
|---|---|
| "Public open-source repo" | Repo flips public day 7 |
| "Screen-recorded video walkthrough" | 3-min video, day 7 |
| "Document tradeoffs and choices" | README "Tradeoffs" + "What I'd build with another two weeks" sections |

## Lines NOT in brief but worth doing
- Privacy claim audit with commit SHAs in README — turns "trust us" into "verify."
- "Questions I struggled with" log in Settings — failed query pipeline pattern from CS Navigator.
- Onboarding 3-screen privacy flow — first impression matters; airplane badge as the visual hero.
- iPhone Air vs 17 Pro Max perf comparison in README — shows awareness of device variance.

## Lines that read like brief but aren't
- "Use Apple Foundation Models" — brief permits it, doesn't require. We chose it for ANE perf + `@Generable` macros + free; document the choice in README.
- "Real-time Q&A" — brief says <3s, not "instant." We hit ~750ms but don't over-promise in copy.
