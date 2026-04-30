> **Archived planning log.** This was a daily brief written before the work shipped. Some component picks (gte-small, sqlite-vec, target latency numbers) were superseded by the actual implementation. For the current architecture see [README.md](../README.md), [DECISIONS.md](../DECISIONS.md), and [THOUGHT-PROCESS.md](../THOUGHT-PROCESS.md).

---

# Day 7 — Demo video + README + submission (Sun May 3)

## What you're shipping today
Polished demo video, finalized README with real perf numbers and Mermaid architecture diagram, public repo flip, submission email to Nirbhay. By end of day this take-home is in.

## Worktree
- Path: `~/Desktop/Aircaps/` (main)
- Branch: `main`

## Pre-flight checks
- [ ] `v0.9.0-rc1` tagged from yesterday.
- [ ] Clean build on a fresh device pair (or device + simulator).
- [ ] `git grep -i "URLSession\|URLRequest\|http://\|https://"` returns zero hits in `Aftertalk/`.
- [ ] iPhone 17 Pro Max charged to 100%, airplane mode toggle accessible from Control Center (long-press).

## Implementation order
1. **README.md finalize** (~2 hrs)
   - Hero gif (record → summary → spoken answer) — produced via QuickTime + Gifski.
   - Real perf numbers from yesterday's profile (TTFSW, ASR TTFT, summary latency, memory peak, battery delta).
   - Mermaid architecture diagram (one-shot, renders inline in GitHub).
   - Component table (model name, size, license, latency).
   - "Built in 7 days during finals week" honesty section.
   - Privacy section: link to specific commit SHAs that introduced each privacy invariant.
   - Build instructions.
   - Stretch goals shipped checklist.
   - Tradeoffs section ("what I'd build with another two weeks").
   - License: MIT.
2. **Demo video record** (~2 hrs, takes multiple retakes)
   - Length: ~3 minutes.
   - Setup: phone in QuickTime as recording source, mic narration optional, Control Center's airplane indicator visible.
   - Scenes (per AirCaps brief expectations):
     1. (0:00) iPhone 17 Pro Max in airplane mode (Control Center visible).
     2. (0:10) Open Aftertalk → 3-screen onboarding.
     3. (0:25) Record 2-min mock standup (Sara + Mark, played from a second device's speaker into the iPhone mic).
     4. (2:30) Stop → live-generating summary (decisions/actions/topics/openQs with speaker labels).
     5. (2:45) Tap mic on chat tab → "what did Sara commit to?" → streaming spoken answer with citation pill.
     6. (3:05) Test barge-in: ask another question, interrupt mid-answer.
     7. (3:25) Switch to Global Chat → cross-meeting question pulling from previously-stored meetings.
     8. (3:45) End on perf badge showing TTFSW + airplane indicator.
   - Edit: trim, add chapter markers, optional voiceover.
   - Upload to YouTube unlisted OR drop the .mov as a GitHub release asset.
3. **Repo flip to public** (~15 min)
   - `gh repo edit theaayushstha1/aftertalk --visibility public`
   - Verify README renders, Mermaid diagram works, hero gif displays.
4. **Tag `v1.0.0`** (~5 min)
   - `git tag -a v1.0.0 -m "v1.0.0 — AirCaps take-home submission"`
   - `git push --tags`
5. **Submission email to Nirbhay** (~30 min)
   - Subject: "Aftertalk — AirCaps take-home submission"
   - Body: short, links to repo + video. See `~/Documents/Aftertalk/60 — Demo & Submission/Submission Email Draft.md` for the draft.
   - Send from `aashr3@morgan.edu` via custom `gmail` skill (`--account school`, with school signature).
6. **Update Obsidian vault** (~30 min)
   - Final daily log entry.
   - "Lessons learned" note in `30 — Learnings/`.
   - Mark all daily logs `status: done`.
   - Index page final update.

## Verification (final acceptance gate before sending)
- [ ] Repo public on GitHub, README renders cleanly with hero gif and Mermaid diagram.
- [ ] Demo video shows airplane indicator throughout, all 5 stretch goals demonstrated.
- [ ] `v1.0.0` tag pushed.
- [ ] Submission email sent + confirmed received (check Sent folder).
- [ ] Build instructions actually work: clone repo on a different machine (or fresh `xcrun simctl`), open Xcode, build to device, complete one record-summarize-Q&A flow.
- [ ] All TODOs in source removed (`git grep -i "TODO\|FIXME"` is clean or each remaining one is intentional and documented).

## Email home plate (FINAL)
- Aftertalk shipped. Public repo: github.com/theaayushstha1/aftertalk. Demo video: <link>.
- All 5 stretch goals delivered (diarization, streaming Q&A, cross-meeting memory, neural TTS, power profile) plus 2 bonus (senior VAD + global chat thread).
- Real perf numbers from MetricKit run (in README): TTFSW <1.5s, peak mem <800MB, battery delta <12% over 40-min session.
- Looking forward to the in-person work trial. Available <dates> in NYC if that's still on the table.

## Demo recording — anti-checklist (don't do these)
- Don't narrate "this is on-device" in the video — let the airplane badge speak. AirCaps engineers will spot it.
- Don't fake the perf badge — show real numbers from `os_signpost` overlay.
- Don't cherry-pick the best take if it's misleading. Show one continuous take that handles a barge-in or a slight stumble — that's what production looks like.
- Don't paraphrase the AirCaps brief in the README. Position as your project.
- Don't include a logo or "Built for AirCaps" branding — it's your repo.

## If you get stuck
- **Hero gif too large for GitHub**: trim to 10s, 720p, ~5MB. Use `ffmpeg -i input.mov -vf "fps=15,scale=720:-1" output.gif`.
- **Mermaid diagram doesn't render in README**: GitHub supports Mermaid in code fences. If it breaks, embed the rendered PNG instead.
- **Submission email bounces**: verify Nirbhay's email from his thread (likely `nirbhay@aircaps.com` or `nirbhay@aircaps.ai`). Cross-check in `~/Documents/Aftertalk/40 — People/Nirbhay (AirCaps).md`.
- **Demo video shows lock screen accidentally**: re-record. Lock screen reveals notifications which can leak personal info.

## After submission
- [ ] Mark all `~/Documents/Aftertalk/` daily logs `status: done`.
- [ ] Add closing note to `~/Documents/Aftertalk/00 — Index.md`: "Submitted 2026-05-03. Awaiting work trial response."
- [ ] Update `~/.claude/projects/-Users-theaayushstha/memory/projects.md` with Aftertalk shipped status.
- [ ] Take a break.
