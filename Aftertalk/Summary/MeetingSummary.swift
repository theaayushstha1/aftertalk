import Foundation
import FoundationModels

@Generable
struct MeetingSummary: Equatable, Sendable {
    @Guide(description: "Concrete decisions reached during the meeting. Each item is a single sentence.")
    var decisions: [String]

    @Guide(description: "Action items committed to during the meeting.", .count(0...20))
    var actionItems: [ActionItem]

    @Guide(description: "Topics discussed. Short noun phrases, ordered by prominence.")
    var topics: [String]

    @Guide(description: "Open questions that were raised but not resolved during the meeting.")
    var openQuestions: [String]
}

@Generable
struct ActionItem: Equatable, Sendable {
    @Guide(description: "What needs to be done. Imperative, one sentence.")
    var description: String

    @Guide(description: "Person responsible if explicitly named in the meeting. Omit the field entirely when no person was named. Never write 'nil', 'null', 'none', or 'unknown'.")
    var owner: String?
}

extension MeetingSummary {
    static let empty = MeetingSummary(decisions: [], actionItems: [], topics: [], openQuestions: [])

    var isEmpty: Bool {
        decisions.isEmpty && actionItems.isEmpty && topics.isEmpty && openQuestions.isEmpty
    }
}
