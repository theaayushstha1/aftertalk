> **Archived planning log.** This was a daily brief written before the work shipped. Some component picks (gte-small, sqlite-vec, target latency numbers) were superseded by the actual implementation. For the current architecture see [README.md](../README.md), [DECISIONS.md](../DECISIONS.md), and [THOUGHT-PROCESS.md](../THOUGHT-PROCESS.md).

---

# Day 3 — Voice Q&A loop end-to-end (Wed Apr 29)

## What you're building today
The full hold-to-talk Q&A: hold button → ASR → hierarchical retrieve → Foundation Models → AVSpeechSynthesizer placeholder → release → answer plays. Latency budget: <2s TTFSW with the placeholder TTS (Kokoro lands tomorrow).

## Worktree
- Path: `~/Desktop/Aircaps-qa/` (spawn today)
- Branch: `feat/qa-loop`

## Pre-flight checks
- [ ] Day 2 verification done. Summary + RAG pipeline working on golden meeting.
- [ ] Spawn worktree: `git worktree add ~/Desktop/Aircaps-qa feat/qa-loop` from `~/Desktop/Aircaps`.
- [ ] `cd ~/Desktop/Aircaps-qa` for this session.

## Files this day touches
- **NEW** `Aftertalk/QA/QAOrchestrator.swift` — orchestrates ASR → retrieve → LLM → TTS
- **NEW** `Aftertalk/QA/SentenceBoundaryDetector.swift` — splits LLM stream on `.!?` + 80-char clamp
- **NEW** `Aftertalk/QA/ChatThreadView.swift` — UI for per-meeting chat thread
- **NEW** `Aftertalk/Retrieval/HierarchicalRetriever.swift` — Layer 1+2 retrieval
- **NEW** `Aftertalk/Retrieval/ContextPacker.swift` — assembles prompt, enforces 2400-token cap
- **NEW** `Aftertalk/TTS/TTSService.swift` — protocol; today's impl wraps `AVSpeechSynthesizer`
- **NEW** `Aftertalk/UI/RecordButton.swift` — animated waveform with hold gesture
- **EDIT** `Aftertalk/UI/MeetingDetailView.swift` — add Chat tab
- **EDIT** `Aftertalk/Persistence/Models/ChatThread.swift` — wire to UI

## Dependencies to add
None today (placeholder TTS uses AVSpeechSynthesizer from AVFoundation).

## Implementation order
1. **Hold-to-talk gesture** on `RecordButton` (~30 min)
   - `LongPressGesture` with `minimumDuration: 0` so it fires immediately.
   - On press: start ASR. On release: finalize.
2. **HierarchicalRetriever** (~2 hrs)
   - Per-meeting Q&A: skip Layer 1, query `TranscriptChunk` rows with `meetingId` filter, top-K=8 by cosine.
   - Embedding query the same way as ChunkIndexer.
3. **ContextPacker** (~1.5 hrs)
   - Render each chunk: `[meeting_title • HH:MM • speaker_label] chunk_text`.
   - Tokenize cumulatively. Stop at 2400 tokens. Use `Session.tokenCount(_:)` if iOS 26.4+, else fall back to char-based heuristic (4 chars ≈ 1 token).
   - Return prompt + citation list.
4. **QAOrchestrator** (~2 hrs)
   - On hold-release: get question text from `MoonshineStreamer`.
   - Embed → retrieve → pack context → call Foundation Models with system prompt: "Answer using only the provided meeting context. Cite speaker names. If the answer isn't there, say 'I don't have that in the meeting transcripts.'"
   - Stream snapshot updates.
5. **SentenceBoundaryDetector** (~1 hr)
   - Consume LLM stream, emit complete sentences on `.!?` or 80-char clamp.
   - Send each sentence to TTSService.
6. **AVSpeechSynthesizer placeholder** (~30 min)
   - Implement `TTSService` protocol with `AVSpeechSynthesizer`.
   - Queue sentences, play sequentially.
7. **Grounding gate** (CS Navigator pattern, ~30 min)
   - In QAOrchestrator: if retrieved chunks all have similarity < 0.4, short-circuit to canned response "I don't have that in the meeting transcripts" — skip the LLM call.
8. **Chat thread persistence** (~1 hr)
   - Each Q+A pair persists as two `Message` rows in the per-meeting `ChatThread`.
   - UI shows scrollable history with citations as inline pills.

## Verification
- [ ] Record golden meeting → ask "what did Sara commit to?" via voice → spoken answer arrives in <2s, references Sara's specific commitment.
- [ ] Ask off-topic question ("what's the weather?") → grounding gate fires, response is the canned disclaimer.
- [ ] Citations: tap a citation pill → transcript jumps to source span, highlighted.
- [ ] Reload app, chat thread persists for the meeting.
- [ ] Logged TTFSW (time-from-release-to-first-spoken-word) is <2s on iPhone 17 Pro Max with placeholder TTS.

## Email home plate
- Voice Q&A loop closed end-to-end: hold button → speak → retrieve → answer plays.
- TTFSW <Xs> on 17 Pro Max with placeholder TTS (target was 3s, will tighten further with Kokoro tomorrow).
- Grounding gate prevents hallucination on off-topic questions (CS Navigator pattern reused).
- Tomorrow: Kokoro neural TTS swap-in + speaker diarization.

## Demo prep
Capture: airplane mode ON → record meeting → ask 3 questions by voice → show citations highlighting transcript → save to `~/Documents/Aftertalk/attachments/2026-04-29-qa-demo.mov`.

## If you get stuck
- **Hold-to-talk gesture conflicts with scroll views**: use `.simultaneousGesture` on the button; SwiftUI gesture priority is finicky.
- **Foundation Models throws "context too long"**: token estimation is wrong; tighten ContextPacker truncation. Use the iOS 26.4 `Session.tokenCount(_:)` if available.
- **Speech synthesizer cuts off mid-word**: don't call `synthesizer.stopSpeaking(at: .immediate)` between sentences; queue them via `AVSpeechSynthesizer.speak(_:)` consecutively.
- **Hierarchical retrieval returns 0 results despite obvious match**: check the embedding distance metric — sqlite-vec defaults to L2; we want cosine. Use `vec_distance_cosine(...)` explicitly.

## End-of-day tasks
- [ ] Commit: `feat(qa): hold-to-talk Q&A loop with hierarchical retrieval, grounding gate, AVSpeechSynthesizer placeholder`
- [ ] Push to `feat/qa-loop`.
- [ ] Append to `~/Documents/Aftertalk/10 — Daily Logs/2026-04-29 — Day 3.md`.
- [ ] Add ADR: "Why grounding gate even on small dataset" (link to CS Navigator pattern note).
- [ ] Send email home plate to Aayush.
