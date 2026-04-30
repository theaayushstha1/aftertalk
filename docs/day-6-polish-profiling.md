> **Archived planning log.** This was a daily brief written before the work shipped. Some component picks (gte-small, sqlite-vec, target latency numbers) were superseded by the actual implementation. For the current architecture see [README.md](../README.md), [DECISIONS.md](../DECISIONS.md), and [THOUGHT-PROCESS.md](../THOUGHT-PROCESS.md).

---

# Day 6 — Polish, edge cases, profiling (Sat May 2)

## What you're building today
Onboarding (3-screen privacy flow), edge case handling (interruptions, silence, long meetings, low memory, low battery), MetricKit profiling run for the perf chart, design pass on UI, error states. By end of day there's a release candidate `v0.9.0-rc1` ready for tomorrow's demo recording.

## Worktree
- Path: `~/Desktop/Aircaps-polish/` on `chore/polish` (or `main` directly if no other worktrees active)
- Branch: `chore/polish`

## Pre-flight checks
- [ ] All feature branches merged to `main`.
- [ ] Clean clone of `main` builds and runs end-to-end on iPhone.
- [ ] Foundation Models, Kokoro, Pyannote, TEN-VAD, SmartTurnV3 all working.

## Files this day touches
- **NEW** `Aftertalk/Onboarding/OnboardingFlow.swift` — 3-screen flow
- **NEW** `Aftertalk/Onboarding/AirplaneModeCheck.swift` — `NWPathMonitor` runtime assertion
- **NEW** `Aftertalk/UI/DesignSystem.swift` — color palette, typography, spacing tokens
- **NEW** `Aftertalk/UI/EmptyStates.swift` — no meetings, no chats, etc.
- **NEW** `Aftertalk/Profiling/PerfReportExporter.swift` — MetricKit dump → CSV → matplotlib chart
- **NEW** `perf/30min-meeting-profile.csv` + `perf/30min-meeting-chart.png` — produced today
- **EDIT** various UI files for design pass
- **EDIT** error handling in QAOrchestrator, MoonshineStreamer, KokoroTTSService

## Implementation order
1. **Onboarding flow** (~2 hrs)
   - Screen 1: "Your meeting, captured and conversational." Big tagline, animated waveform.
   - Screen 2: "Nothing leaves the device." NWPathMonitor live status indicator + 3-line privacy promise.
   - Screen 3: "Allow microphone." Native permission request.
   - Persist completion in `UserDefaults`; subsequent launches skip onboarding.
2. **AirplaneModeCheck** (~1 hr)
   - `NWPathMonitor` assertion: if any interface is `.satisfied` while a meeting is recording, log a warning, surface a non-blocking banner. Do not abort.
   - Settings tab shows current network status (green = airplane).
3. **DesignSystem + design pass** (~2 hrs)
   - Tokens: dark + light mode palettes, type scale, radii, spacing.
   - Apply across MeetingsList, MeetingDetail, ChatThread, GlobalChat, RecordButton.
   - Microinteractions: record button bounce on tap, transcript word fade-in, citation pill press feedback.
4. **Edge cases** (~2 hrs)
   - **Interruption mid-recording**: phone call comes in. AVAudioSession resumes recording after call ends, with a 1-sec gap marker in transcript.
   - **Long silence in meeting**: transcript shows nothing; recording continues; meeting metadata shows "no speech detected for 2:30."
   - **Long meeting (>60min)**: chunk count gets large. Test that Layer 2 retrieval still completes in <100ms.
   - **Low memory**: handle `didReceiveMemoryWarning` by flushing Pyannote/Kokoro caches.
   - **Low battery (<10%)**: banner suggests stopping recording; don't auto-stop.
   - **No previous meetings**: empty state on MeetingsList with CTA to record first.
5. **Profiling run** (~1.5 hrs)
   - Record 30-min meeting (play back a YouTube panel into the mic, with airplane mode ON of course — meeting plays from speaker, recording on a different device).
   - Run 10-min Q&A session (10 questions across the meeting).
   - MetricKit captures peak memory, average CPU, ANE residency, thermal state, battery delta.
   - Export CSV, render matplotlib chart with 4 subplots.
6. **Tag `v0.9.0-rc1`** (~30 min) — first release candidate.

## Verification
- [ ] Cold launch app first time → onboarding flow plays. Cold launch second time → goes straight to meetings list.
- [ ] Phone call mid-recording: recording pauses + resumes cleanly.
- [ ] 60-min recording produces ~120 chunks; Layer 2 retrieval still <100ms.
- [ ] MetricKit profile shows: peak memory <800MB, thermal `.fair` or below, battery delta <12% over 40 min.
- [ ] Privacy banner shows green throughout 40-min session.
- [ ] No SwiftUI warnings (`[Layout] modifying state during view update`).
- [ ] All UI flows work in both light and dark mode.

## Email home plate
- Polish day: onboarding shipped, edge cases handled, design pass done.
- Profiling complete: peak memory <Xmb>, battery delta <X%> over 40-min session, thermal stayed in `.fair`.
- Release candidate `v0.9.0-rc1` tagged.
- Tomorrow: demo recording + README finalize + submission.

## Demo prep
Today's recording is the **profile session** itself — that becomes the perf chart. Tomorrow records the actual demo video.

## If you get stuck
- **Onboarding feels generic**: lean on the airplane-mode badge as the visual hero. The privacy promise is the unique pitch — make the badge animate, glow green when it activates.
- **MetricKit data not arriving in app**: use `MXMetricManager.shared.add(self)` at app launch; data arrives next launch via `didReceive payloads:`. For dev, use `Xcode → Debug → Replay Metrics`.
- **Profile chart has gaps**: MetricKit aggregates per-day, not per-session. For the take-home, you can sample directly via `os_signpost` + a custom logger and chart that instead. Both are acceptable.
- **Design pass eating too much time**: cap at 2 hrs. If unfinished, ship what's done. The brief grades on functionality + perf, not pixel polish.

## End-of-day tasks
- [ ] Commit: `chore: onboarding, edge cases, design pass, profiling run`
- [ ] Tag: `git tag v0.9.0-rc1 && git push --tags`
- [ ] Append to `~/Documents/Aftertalk/10 — Daily Logs/2026-05-02 — Day 6.md`.
- [ ] Send email home plate.
