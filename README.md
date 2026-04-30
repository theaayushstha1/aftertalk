<div align="center">

<img src="docs/assets/logos/aftertalk-logo-512.png" width="120" alt="Aftertalk logo" />

# Aftertalk

### Meeting memory that never leaves your phone.

<a href="docs/assets/aftertalk-demo.mp4">
  <img src="docs/assets/aftertalk-demo.gif" alt="Aftertalk iPhone demo: recording, structured summary, voice Q&A" width="320">
</a>

<sub><a href="docs/assets/aftertalk-demo.mp4">▶︎ watch the 22-second walkthrough (MP4)</a></sub>

<br />

<!-- Status badges -->

[![iOS 26+](https://img.shields.io/badge/iOS-26%2B-1B1B1F?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-2096FF?style=for-the-badge&logo=swift&logoColor=white)](https://developer.apple.com/swiftui/)
[![Foundation Models](https://img.shields.io/badge/Foundation%20Models-2F7D55?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/documentation/FoundationModels)
[![Network zero](https://img.shields.io/badge/Network-zero-1B1B1F?style=for-the-badge&logo=apple&logoColor=white)](#privacy)
[![License: MIT](https://img.shields.io/badge/License-MIT-FFC107?style=for-the-badge)](LICENSE)
[![Tests](https://img.shields.io/badge/tests-33%20passing-2F7D55?style=for-the-badge&logo=swift&logoColor=white)](#tests)

<br />

<!-- Built-with cluster: clickable links to each upstream -->

[![Swift 6](https://img.shields.io/badge/Swift_6-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-2096FF?style=flat-square&logo=swift&logoColor=white)](https://developer.apple.com/swiftui/)
[![SwiftData](https://img.shields.io/badge/SwiftData-1B1B1F?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/documentation/SwiftData)
[![Foundation Models](https://img.shields.io/badge/Foundation%20Models-2F7D55?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/documentation/FoundationModels)
[![Core ML](https://img.shields.io/badge/Core%20ML-1B1B1F?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/documentation/coreml)
[![NLContextual](https://img.shields.io/badge/NLContextual-1B1B1F?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding)
[![Moonshine](https://img.shields.io/badge/Moonshine-FFC107?style=flat-square)](https://github.com/moonshine-ai/moonshine-swift)
[![FluidAudio](https://img.shields.io/badge/FluidAudio-4F68A8?style=flat-square)](https://github.com/FluidInference/FluidAudio)
[![Pyannote](https://img.shields.io/badge/Pyannote-7450A8?style=flat-square)](https://github.com/pyannote/pyannote-audio)
[![Kokoro TTS](https://img.shields.io/badge/Kokoro%2082M-B4532A?style=flat-square)](https://github.com/FluidInference/FluidAudio)

<br />

<!-- One-line nav: every section + the long-form docs are one click away -->

[**Demo**](#demo) · [**Architecture**](#architecture) · [**Q&A flow**](#qa-flow) · [**Stack**](#stack) · [**Privacy**](#privacy) · [**Build**](#build) · [**Tests**](#tests) · [**Status**](#status) · [**Decisions**](DECISIONS.md) · [**How it was built**](THOUGHT-PROCESS.md)

</div>

---

## What it does

| **Capture** | **Understand** | **Ask** |
|---|---|---|
| Live Moonshine streaming ASR while you record. | Foundation Models extracts decisions, action items, topics, open questions. | Hold-to-talk Q&A on this meeting **or** all of them. |
| Optional Parakeet polish for word-accurate timing. | NLContextual embeddings + BM25 + RRF for hybrid retrieval. | Streaming answers with citation pills, optional Kokoro TTS. |
| Pyannote diarization for speaker-attributed chunks. | Sentence-aligned chunks indexed in SwiftData on the phone. | Soft grounding gate, full-transcript context for short meetings. |

---

<a id="demo"></a>

## Product tour

<div align="center">

<table>
  <tr>
    <td align="center"><img src="docs/assets/readme-record.png" width="200" alt="Live recording"><br><sub><b>Record</b></sub></td>
    <td align="center"><img src="docs/assets/readme-meetings.png" width="200" alt="Meetings"><br><sub><b>Meetings</b></sub></td>
    <td align="center"><img src="docs/assets/readme-summary.png" width="200" alt="Summary"><br><sub><b>Summary</b></sub></td>
    <td align="center"><img src="docs/assets/readme-transcript.png" width="200" alt="Transcript"><br><sub><b>Transcript</b></sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/assets/readme-actions.png" width="200" alt="Actions"><br><sub><b>Actions</b></sub></td>
    <td align="center"><img src="docs/assets/readme-ask.png" width="200" alt="Ask"><br><sub><b>Ask</b></sub></td>
    <td align="center"><img src="docs/assets/readme-search.png" width="200" alt="Search"><br><sub><b>Search</b></sub></td>
    <td align="center"><img src="docs/assets/readme-global-chat.png" width="200" alt="Global chat"><br><sub><b>Global</b></sub></td>
  </tr>
</table>

</div>

---

<a id="architecture"></a>

## <img src="https://cdn.simpleicons.org/apple/1B1B1F" width="22" align="absmiddle" /> Architecture

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'primaryColor': '#F5E7D0', 'primaryTextColor': '#1D1712', 'primaryBorderColor': '#B4532A', 'lineColor': '#8A5A44', 'secondaryColor': '#E7F1EA', 'tertiaryColor': '#E7ECF8', 'fontFamily': 'Inter, ui-sans-serif, system-ui'}}}%%
flowchart LR
    A([iPhone mic]):::capture --> B[Moonshine live ASR]:::model
    B --> C[Live transcript]:::ui
    A --> D[WAV on device]:::data
    D --> E[Parakeet polish]:::model
    D --> F[FluidAudio diarization]:::model
    E --> G[Canonical transcript]:::data
    F --> G
    G --> H[Chunks + summary]:::data
    H --> I[NLContextualEmbedding]:::model
    H --> J[Foundation Models summary]:::model
    I --> K[(SwiftData)]:::store
    J --> K
    H --> K
    K --> L[Search]:::ui
    K --> M[Meeting chat]:::ui
    K --> N[Global chat]:::ui

    classDef capture fill:#F7D9C4,stroke:#B4532A,color:#1D1712;
    classDef model fill:#E7ECF8,stroke:#4F68A8,color:#172033;
    classDef data fill:#FFF4CC,stroke:#A07708,color:#2D2200;
    classDef store fill:#E7F1EA,stroke:#2F7D55,color:#102418;
    classDef ui fill:#F0E7FF,stroke:#7450A8,color:#241338;
```

<a id="qa-flow"></a>

## <img src="https://cdn.simpleicons.org/swift/F05138" width="22" align="absmiddle" /> Q&A flow

```mermaid
%%{init: {'theme': 'base', 'themeVariables': {'actorBkg': '#F5E7D0', 'actorBorder': '#B4532A', 'signalColor': '#4F68A8', 'activationBkgColor': '#E7F1EA', 'noteBkgColor': '#FFF4CC', 'fontFamily': 'Inter, ui-sans-serif, system-ui'}}}%%
sequenceDiagram
    autonumber
    participant U as User
    participant ASR as Question ASR
    participant Q as QAOrchestrator
    participant R as Hybrid retriever
    participant DB as SwiftData
    participant LLM as Foundation Models
    participant TTS as Local TTS

    U->>ASR: hold-to-talk question
    ASR-->>Q: local transcript
    alt Short meeting (≤ ~10k chars)
        Q->>DB: full transcript + structured summary
        Q->>R: best-effort retrieval (citations only)
    else Larger / global
        Q->>R: dense + BM25 + RRF fusion
        R->>DB: chunks, summaries, embeddings
    end
    DB-->>Q: packed context
    Q->>LLM: stream answer locally
    loop sentence stream
        LLM-->>Q: snapshot
        Q-->>U: chat bubble + citations
        Q->>TTS: speak completed sentence
    end
```

<a id="stack"></a>

## <img src="https://cdn.simpleicons.org/swift/F05138" width="22" align="absmiddle" /> Stack

| Layer | Implementation | Notes |
|---|---|---|
| App shell | <img src="https://cdn.simpleicons.org/swift/F05138" width="14" /> SwiftUI · SwiftData · AVAudioEngine | iOS 26+, Swift 6 strict concurrency |
| Live ASR | <img src="https://cdn.simpleicons.org/apple/1B1B1F" width="14" /> **Moonshine small streaming** + EnergyVADGate | Real-time live preview; Parakeet produces the canonical transcript |
| Polish ASR | <img src="https://cdn.simpleicons.org/apple/1B1B1F" width="14" /> FluidAudio **Parakeet TDT 0.6B v2** | Word-accurate timings, ~0.5× real-time |
| Diarization | <img src="https://cdn.simpleicons.org/apple/1B1B1F" width="14" /> FluidAudio Pyannote 3.1 + WeSpeaker v2 | Best-effort labels, `clusteringThreshold=0.5` + ghost-cluster cleanup |
| LLM | <img src="https://cdn.simpleicons.org/apple/1B1B1F" width="14" /> Apple **Foundation Models** | 4096-token context, structured `@Generable` summary |
| Embeddings | <img src="https://cdn.simpleicons.org/apple/1B1B1F" width="14" /> Apple **NLContextualEmbedding** (512-dim) | System asset, no shipped weights |
| Retrieval | <img src="https://cdn.simpleicons.org/swift/F05138" width="14" /> Dense + **BM25** + **Reciprocal Rank Fusion** | Full-transcript path for short meetings |
| Storage | <img src="https://cdn.simpleicons.org/apple/1B1B1F" width="14" /> SwiftData rows + app-local audio files | Cascade delete + repair tool for degraded indexes |
| TTS | <img src="https://cdn.simpleicons.org/apple/1B1B1F" width="14" /> FluidAudio **Kokoro 82M** (ANE) | AVSpeechSynthesizer fallback |

<a id="privacy"></a>

## <img src="https://cdn.simpleicons.org/letsencrypt/2F7D55" width="22" align="absmiddle" /> Privacy

Aftertalk is built so meeting content never leaves the phone.

| Layer | Guarantee |
|---|---|
| Runtime network | No production `URLSession` or `URLRequest` usage in app Swift sources. |
| Capture | Recording and Q&A run locally once model assets are present. |
| Storage | Audio, transcript, summary, chat, and embeddings are app-local. |
| Verification | Settings includes a live privacy audit and model-asset status. |

```bash
git grep -nE "URLSession|URLRequest" -- 'Aftertalk/**/*.swift'
# returns zero matches in production sources
```

<a id="build"></a>

## <img src="https://cdn.simpleicons.org/xcode/1575F9" width="22" align="absmiddle" /> Build

```bash
git clone https://github.com/theaayushstha1/aftertalk
cd aftertalk
xcodegen generate

# Local model bundles (gitignored, downloaded by these scripts)
./Scripts/fetch-parakeet-models.sh
./Scripts/fetch-kokoro-models.sh
./Scripts/fetch-pyannote-models.sh

# Moonshine .ort weights go under
# Aftertalk/Models/moonshine-small-streaming-en/

open Aftertalk.xcodeproj
```

Requirements: Xcode 17+, iOS 26+ device, Apple Developer signing.

<a id="tests"></a>

## <img src="https://cdn.simpleicons.org/swift/F05138" width="22" align="absmiddle" /> Tests

```bash
xcodebuild test -scheme Aftertalk \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

33 tests across 6 suites — VAD gating, sentence boundary detection, title sanitization, diarization cluster cleanup, BM25 tokenization, and RRF fusion. The diarization regression test explicitly encodes the ghost-cluster cycle bug that broke speaker labels under degraded acoustic conditions.

<a id="status"></a>

## <img src="https://cdn.simpleicons.org/github/1B1B1F" width="22" align="absmiddle" /> Status

**Shipping**

- Record · live transcript · structured summary · transcript detail · action items · search · per-meeting chat · global chat · Settings privacy audit.
- Q&A avoids the old low-cosine refusal: full-transcript context for short meetings, hybrid dense+BM25+RRF for larger or cross-meeting queries.
- Soft grounding gate refuses only when there are truly no chunks AND no summary on the device.
- Embedding fallback + dim-mismatch filter so degraded indexes can't poison live retrieval.
- Repair tool re-embeds chunks and creates missing summary embeddings when a working embedding service comes back online.
- Optional model assets degrade explicitly with banners instead of silently breaking the recording path.

**Known limits**

- Far-field classrooms are microphone-limited; a phone across a room cannot match a lapel mic near the speaker. The `RecordingProfile.farField` plumbing exists but isn't user-toggleable yet.
- Single-channel diarization labels are best-effort, especially on PC-speaker-played audio or heavy room reverb. FluidAudio's `OfflineDiarizerManager` + VBx is the documented next step.
- Pipeline parallelism. Polish and diarization run concurrently today via `async let`; full background diarization (chunk + summarize from polish alone) is deferred for submission stability.
- Final 30-min + 10-min device perf chart still pending a real-device capture run.

---

## <img src="https://cdn.simpleicons.org/opensourceinitiative/3DA639" width="22" align="absmiddle" /> License

[![License: MIT](https://img.shields.io/badge/License-MIT-FFC107?style=for-the-badge)](LICENSE)

Released under the [MIT License](LICENSE). Use it commercially, fork it, ship it, study it, modify it. The only ask is that the copyright notice and permission text travel with the source. No warranty.

```text
MIT License · Copyright (c) 2026 Aayush Shrestha
```

## Credits

[Moonshine ASR](https://github.com/moonshine-ai/moonshine-swift) by Useful Sensors · [FluidAudio](https://github.com/FluidInference/FluidAudio) by Fluid Inference · Apple Foundation Models · Apple NLContextualEmbedding · [Pyannote](https://github.com/pyannote/pyannote-audio) by Hervé Bredin et al.

---

<div align="center">

<sub>Built in 7 days during finals week by <a href="https://github.com/theaayushstha1">Aayush Shrestha</a>. Read the <a href="DECISIONS.md">architecture decisions</a> or the <a href="THOUGHT-PROCESS.md">day-by-day build log</a> for the full engineering reasoning.</sub>

</div>
