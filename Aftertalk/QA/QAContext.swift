import Foundation

/// Bundles the Q&A pipeline dependencies so MeetingDetailView and
/// ChatThreadView can share a single configured pipeline instance.
@MainActor
struct QAContext {
    let orchestrator: QAOrchestrator
    let questionASR: QuestionASR
    let repository: MeetingsRepository
}
