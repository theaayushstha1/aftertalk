> **Archived planning log.** This was a daily brief written before the work shipped. Some component picks (gte-small, sqlite-vec, target latency numbers) were superseded by the actual implementation. For the current architecture see [README.md](../README.md), [DECISIONS.md](../DECISIONS.md), and [THOUGHT-PROCESS.md](../THOUGHT-PROCESS.md).

---

# Day 5 — 24-hour update (to Nirbhay)

**Date**: Tuesday Apr 28, 2026
**Sent**: end of day, by Aayush
**Days remaining**: 2 (submission Sun May 3, EOD ET)

---

## Email home plate (4 bullets)

- **Day 5: Quiet Studio refactor closes + Settings privacy audit live.** Full editorial UI pass against the QS handoff — Onboarding, Record, Meetings, Detail (Summary/Transcript/Actions), Ask, Global Ask, Settings — all on shared `QSEyebrow/Title/Body/PrivacyBadge/Divider/BreathingOrb/ImmersiveWaveform` primitives, light + dark palette, `\.atPalette` environment key.
- **Cross-meeting memory shipped earlier in the week is now wired to the UI.** Global Ask thread (`ChatThread.isGlobal`) routes through Layer 1 + Layer 2 of the hierarchical retriever; citation pills carry meeting title for global mode, timestamps for per-meeting. Grounding-gate widened so newly recorded meetings surface in global Ask without a re-index round trip.
- **Settings is the visible proof for the "Privacy as policy" claim.** Live audit reads real device state per render — `@Query` counts for meetings + chunks, `FileManager` probes via `ModelLocator` for the four model bundles, `PrivacyMonitor.state` for the network row, and a Verify button that runs an actual probe sequence. Nothing on that screen is hand-waved or cached. Decision recorded: [`ADR-016 Settings audit reads only real device state`](../20%20%E2%80%94%20Decisions/ADR-016%20Settings%20audit%20reads%20only%20real%20device%20state.md).
- **Tomorrow (Day 6):** custom Quiet Studio bottom tab bar + center record FAB, MetricKit profiling pass (30-min recording + 10-min Q&A → `perf/`), edge cases (interruptions, long meetings, low memory). Cut `v0.9.0-rc1` if device pass is clean.

---

## Numbers

- Build: green on `xcodebuild -destination 'generic/platform=iOS'` after every UI change today.
- Last measured perf (held from Day 4 since Day 5 was UI-only): **TTFT 104 ms, total Q&A turn 1,440 ms** on iPhone Air. MetricKit run scheduled for Day 6.
- Privacy claim: `git grep -i "URLSession\|URLRequest\|http://\|https://" Aftertalk/` still returns zero in production paths. `NWPathMonitor` runtime assertion + green airplane badge in chrome.

## Today's commits (main)

- `ebf82d1` feat(ui): land Quiet Studio refactor + SettingsView privacy surface
- (incoming) fix(ui): hardcode ink/faint on NavigationLink + AuditRow to defeat SwiftUI button-tint inheritance, hide DebugOverlay, swap Ask navigation to fullScreenCover

## Stretch goals status

| ID | Stretch | Status |
|---|---|---|
| S1 | Speaker diarization (Pyannote Core ML) | ✅ Day 4 |
| S2 | Streaming Q&A (sentence-boundary → TTS) | ✅ Day 4 |
| S3 | Cross-meeting memory + global chat | ✅ Day 5 |
| S4 | Neural TTS (Kokoro 82M ANE) | ✅ Day 4 |
| S5 | Power profile (MetricKit, 30-min meeting + 10-min Q&A) | ⏳ Day 6 |
| S6 | Senior-grade VAD + barge-in | ➖ TEN-VAD swap deferred — energy heuristics + auto-rearm proved sufficient on hardware; doc retained for Day 6 if regressions surface |
| S7 | Per-meeting + global chat with citations | ✅ Day 5 |

5 of 7 stretches shipped, 1 in flight, 1 deliberately deferred with documented rationale.

## What's at risk

- Day 6 has two real items competing for budget: custom QS tab bar (significant restructure) vs MetricKit perf capture. If tab bar slips, the current 4-tab `TabView` ships and demo records against it — visually less distinctive but functionally identical. Profiling is non-negotiable.
- iPhone Air jetsam ceiling under simultaneous Foundation Models + Pyannote + Parakeet + Kokoro residency remains the tightest budget item; lazy-warm pattern is holding but every new feature gets a memory review before merge.

## Tomorrow's plan (Day 6, Wed Apr 29)

1. On-device verification pass on every QS screen (Onboarding → Record → Meetings → Detail → Ask → Global → Settings) — golden-path + edge cases.
2. NWPathMonitor airplane-mode badge polish.
3. MetricKit profiling run → perf chart in `/perf/`.
4. Decide: ship custom tab bar or freeze 4-tab layout. Document either way.
5. Cut `v0.9.0-rc1`.
