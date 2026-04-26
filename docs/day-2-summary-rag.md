# Day 2 — Structured summary + RAG pipeline (Tue Apr 28)

## What you're building today
After a recording stops, the app generates a structured `MeetingSummary` (decisions, action items with owners, topics, open questions) via Apple Foundation Models. Transcript is chunked, embedded with gte-small Core ML, and stored in sqlite-vec for tomorrow's Q&A retrieval.

## Worktree
- Path: `~/Desktop/Aircaps/` (main branch — RAG and summary are sequential, no fork yet)
- Branch: `main`

## Pre-flight checks
- [ ] Day 1 verification fully checked off.
- [ ] iPhone is on iOS 18.0+ with Foundation Models available in user's region.
- [ ] gte-small Core ML model converted and bundled in Xcode asset catalog.

## Files this day touches
- **NEW** `Aftertalk/Persistence/ModelContainer+Aftertalk.swift` — SwiftData container, registers all models
- **NEW** `Aftertalk/Persistence/Models/Meeting.swift`, `TranscriptChunk.swift`, `SpeakerLabel.swift`, `MeetingSummaryEmbedding.swift`
- **NEW** `Aftertalk/Persistence/SQLiteVecBootstrap.swift` — load `sqlite-vec` extension at app launch
- **NEW** `Aftertalk/Summary/MeetingSummary.swift` — `@Generable` struct (decisions, actions[owner?], topics, openQs)
- **NEW** `Aftertalk/Summary/SummaryGenerator.swift` — Foundation Models call
- **NEW** `Aftertalk/Summary/ChunkIndexer.swift` — sentence-window chunking + embeddings
- **NEW** `Aftertalk/Retrieval/EmbeddingService.swift` — gte-small Core ML wrapper (`MLModel`)
- **NEW** `Aftertalk/Retrieval/VectorStore.swift` — sqlite-vec query layer
- **NEW** `Aftertalk/UI/MeetingsListView.swift` — list of recorded meetings
- **NEW** `Aftertalk/UI/MeetingDetailView.swift` — transcript + summary tabs
- **EDIT** `Aftertalk/App/RootView.swift` — wire MeetingsList + Record together

## Dependencies to add
- **SPM**: `https://github.com/asg017/sqlite-vec.git` (Swift package wrapper, may need fork for iOS extension loading — check if `loadable_extension` is available on iOS Sandboxed apps)
- **Bundled**: `gte-small.mlpackage` Core ML conversion (from HuggingFace `thenlper/gte-small`, convert via `coremltools`)

## Implementation order
1. **SwiftData container + models** (~1 hr)
   - Define all `@Model` classes per `ARCHITECTURE.md`.
   - Bootstrap `ModelContainer` in `AftertalkApp.swift`.
2. **sqlite-vec extension load** (~1 hr, **highest risk item of the day**)
   - Locate the SwiftData SQLite file path at runtime.
   - Open a parallel `sqlite3` connection, call `sqlite3_load_extension(...)` for `vec0`.
   - **If iOS sandbox blocks extension loading**: fall back to VecturaKit (pure Swift) — switch behind `VectorStore` protocol.
3. **Embedding service** (~1.5 hr)
   - Load `gte-small.mlpackage` via `MLModel`.
   - Tokenize input (gte-small uses BERT WordPiece — may need a small tokenizer port; check HF `tokenizers` Swift bindings).
   - Output 384-dim float32 vector.
4. **ChunkIndexer** (~1 hr)
   - Window by sentence with 30-second overlap, max 4 sentences per chunk.
   - For each chunk: text, startSec, endSec, embed, store in `TranscriptChunk` + sqlite-vec.
5. **MeetingSummary `@Generable` schema** (~1 hr)
   - Struct with `decisions: [String]`, `actionItems: [ActionItem]` where `ActionItem { description: String, owner: String? }`, `topics: [String]`, `openQuestions: [String]`.
   - Test on a synthetic 5-min transcript (Sara + Mark startup standup) — store as `golden/test-meeting-1.txt`.
6. **SummaryGenerator** (~1 hr)
   - Foundation Models session with 4K budget, system prompt: "Extract decisions, action items (with owners where attributable), topics, open questions from this meeting transcript. Be concise."
   - Stream snapshot updates so UI shows summary forming.
7. **MeetingsListView + MeetingDetailView** (~1.5 hr)
   - List of meetings with last summary preview.
   - Detail: transcript top, summary 4 sections below, chat tab placeholder.

## Verification
- [ ] Record golden 5-min synthetic meeting → summary appears within 8s of stop.
- [ ] Summary contains the seeded decisions ("Hire Sara for design role"), action items ("Mark to draft PRD by Friday"), topics, open questions.
- [ ] Snapshot test passes on 5-min golden transcript.
- [ ] sqlite-vec table contains 5-15 chunks with non-zero embeddings.
- [ ] Cold-start: open app, list shows previously recorded meetings persisted.

## Email home plate
- Structured summary live: decisions, action items with owners, topics, open questions — all generated on-device via Apple Foundation Models.
- Latency: <Xs> for a 5-min meeting (target was 8s).
- RAG indexed: 384-dim gte-small embeddings into sqlite-vec, ready for tomorrow's Q&A.
- Tomorrow: voice Q&A loop with hold-to-talk.

## Demo prep
Capture: record golden meeting → show streaming summary forming → tap a decision item, see source span highlighted in transcript. Save to `~/Documents/Aftertalk/attachments/2026-04-28-summary-demo.mov`.

## If you get stuck
- **Foundation Models not available in region**: drop to MLX Swift + Phi-4-mini behind `LLMService` protocol. Adds ~6 hrs.
- **sqlite-vec extension blocked by iOS sandbox**: use VecturaKit. Pure Swift, no SQLite extension surgery, slightly slower on >10K rows. Acceptable for take-home scope.
- **gte-small Core ML conversion fails**: use `NLContextualEmbedding` from Apple's NaturalLanguage framework as the embedding backend. ~512-dim, slightly worse recall, but free.
- **`@Generable` schema not respected by Foundation Models**: print the raw output, check token cap. Often the issue is the prompt asking for too many fields and overflowing the 4K budget. Trim system prompt.

## End-of-day tasks
- [ ] Commit: `feat(summary): structured MeetingSummary via Foundation Models + RAG pipeline (gte-small + sqlite-vec)`
- [ ] Append to `~/Documents/Aftertalk/10 — Daily Logs/2026-04-28 — Day 2.md`.
- [ ] If sqlite-vec was a no-go, add ADR documenting the VecturaKit fallback decision.
- [ ] Send email home plate to Aayush.
