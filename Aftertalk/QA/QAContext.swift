import Foundation

/// Bundles the Q&A pipeline dependencies so MeetingDetailView and
/// ChatThreadView can share a single configured pipeline instance.
@MainActor
struct QAContext {
    let orchestrator: QAOrchestrator
    let questionASR: QuestionASR
    let repository: MeetingsRepository
    /// `false` when `NLContextualEmbeddingService` couldn't load its system
    /// asset on this device — Q&A retrieval can't ground answers, so we
    /// gate the chat surfaces with a banner instead of silently returning
    /// the "I don't have that" disclaimer for every question. Recording,
    /// summary generation, and meeting persistence still work.
    let semanticQAAvailable: Bool
}
