# Aftertalk — Worktree Strategy

The 7-day sprint is parallelizable across 4 logical workstreams once day 1's audio capture is in place. We use git worktrees so each Claude Code session can work on a different branch without context-switching cost.

## Setup (run once on day 0)
```bash
cd ~/Desktop/Aircaps
git init
git remote add origin git@github.com:theaayushstha1/aftertalk.git
git checkout -b main
git add CLAUDE.md PRD.md ARCHITECTURE.md WORKTREES.md README.md docs/ .gitignore
git commit -m "chore: project bootstrap (PRD, architecture, daily briefs)"
git push -u origin main

# create feature branches
for branch in asr-streaming summary-rag qa-loop kokoro-tts vad-bargein polish; do
  git branch feat/$branch
done
git push origin --all

# spawn worktrees on demand (only when needed — see schedule)
# git worktree add ../Aircaps-asr feat/asr-streaming
# git worktree add ../Aircaps-summary feat/summary-rag
# git worktree add ../Aircaps-qa feat/qa-loop
# git worktree add ../Aircaps-tts feat/kokoro-tts
# git worktree add ../Aircaps-vad feat/vad-bargein
# git worktree add ../Aircaps-polish chore/polish
```

## Per-day worktree assignments

| Day | Active worktree(s) | Why |
|---|---|---|
| 1 (Mon Apr 27) | main only | foundational — audio capture must land before anything forks |
| 2 (Tue Apr 28) | main only | summary + RAG are sequential on day 1 |
| 3 (Wed Apr 29) | `Aircaps-qa` | QA loop on its own branch; main stays clean |
| 4 (Thu Apr 30) | `Aircaps-tts` AND `Aircaps-summary` (diarization) in parallel | two Claude sessions can run concurrently |
| 5 (Fri May 1) | `Aircaps-vad` AND `Aircaps-qa` (cross-meeting in parallel) | VAD is isolated; cross-meeting builds on QA |
| 6 (Sat May 2) | `Aircaps-polish` only | merge everything, polish, profile |
| 7 (Sun May 3) | main only | tag, video, README, submit |

## Merge cadence
- **Day 4 EOD**: merge `feat/asr-streaming` and `feat/summary-rag` into main. Resolve conflicts manually.
- **Day 5 EOD**: merge `feat/qa-loop` and `feat/kokoro-tts`.
- **Day 6 morning**: merge `feat/vad-bargein`. Cut release candidate tag `v0.9.0-rc1`.
- **Day 7**: tag `v1.0.0` after demo video records cleanly.

## How to start a new Claude session in a worktree
1. `cd ~/Desktop/Aircaps-<workstream>`
2. Open a fresh Claude Code session.
3. Claude auto-loads `CLAUDE.md` (it's the same file in every worktree — git tracks it).
4. Tell Claude: "Continue work in worktree X, day N." Claude reads `docs/day-N-*.md` and executes.
5. Claude commits + pushes to `feat/<branch>` at session end. Logs progress to `~/Documents/Aftertalk/10 — Daily Logs/<today>.md`.

## Conflict avoidance
- Each workstream owns its own folder under `Aftertalk/` (see `ARCHITECTURE.md` "Project file structure"). Conflicts are rare because the surface area doesn't overlap.
- Shared files (`AftertalkApp.swift`, `RootView.swift`, `ModelContainer+Aftertalk.swift`) are only edited in the `main` worktree by whoever finishes their feature first that day.
- `Aftertalk.xcodeproj` conflicts: Xcode project file merge conflicts are notoriously bad.
  - **Rule**: only edit project structure (target settings, build phases, schemes) in `main`.
  - **Adding files**: feature branches add files via SPM whenever possible. If a new Swift file MUST be added to the Xcode target, it's added in `main` via a follow-up commit after the feature branch merges.

## Worktree tear-down
When a feature branch merges, remove its worktree to keep the desktop clean:
```bash
git worktree remove ~/Desktop/Aircaps-<workstream>
git branch -d feat/<branch>   # only after merge to main is confirmed
```
