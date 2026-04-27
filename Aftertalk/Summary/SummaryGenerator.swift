import Foundation
import FoundationModels
import os

protocol LLMService: Sendable {
    func generateSummary(transcript: String) async throws -> (summary: MeetingSummary, latencyMillis: Double)
    func streamSummary(transcript: String) -> AsyncThrowingStream<MeetingSummary.PartiallyGenerated, any Error>
}

enum SummaryError: Error, CustomStringConvertible {
    case modelUnavailable(String)
    case generationFailed(String)

    var description: String {
        switch self {
        case .modelUnavailable(let why): "Foundation Models unavailable: \(why)"
        case .generationFailed(let why): "Summary generation failed: \(why)"
        }
    }
}

final class FoundationModelsSummaryGenerator: LLMService, @unchecked Sendable {
    private let log = Logger(subsystem: "com.theaayushstha.aftertalk", category: "Summary")

    private static let systemInstructions = """
    You extract structured notes from a meeting transcript.

    Rules:
    - Every field must be grounded in the transcript. Do not invent information.
    - "decisions" are concrete things the meeting agreed on.
    - "actionItems" are commitments. Set "owner" only when a name is explicitly attached in the transcript.
    - "topics" are short noun phrases summarising what was discussed.
    - "openQuestions" are questions raised but not resolved.
    - Be concise. Prefer fewer high-quality items over many vague ones.
    - If the transcript is too short or empty, return empty arrays for all fields.
    """

    private func availability() throws {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw SummaryError.modelUnavailable("\(reason)")
        @unknown default:
            throw SummaryError.modelUnavailable("unknown availability")
        }
    }

    private func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: Self.systemInstructions)
    }

    private func prompt(for transcript: String) -> String {
        """
        Transcript follows. Extract decisions, action items (with owners where attributable), topics, open questions.

        --- TRANSCRIPT ---
        \(transcript)
        --- END ---
        """
    }

    func generateSummary(transcript: String) async throws -> (summary: MeetingSummary, latencyMillis: Double) {
        try availability()
        let session = makeSession()
        let started = ContinuousClock.now
        do {
            let response = try await session.respond(
                to: prompt(for: transcript),
                generating: MeetingSummary.self
            )
            let elapsed = started.duration(to: .now)
            return (response.content, elapsed.aftertalkMillis)
        } catch {
            log.error("summary failed: \(String(describing: error), privacy: .public)")
            throw SummaryError.generationFailed("\(error)")
        }
    }

    func streamSummary(transcript: String) -> AsyncThrowingStream<MeetingSummary.PartiallyGenerated, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try self.availability()
                    let session = self.makeSession()
                    let stream = session.streamResponse(
                        to: self.prompt(for: transcript),
                        generating: MeetingSummary.self
                    )
                    for try await snapshot in stream {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

