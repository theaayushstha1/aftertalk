import Foundation
import FoundationModels

@Generable
struct MeetingSummary: Equatable, Sendable {
    @Guide(description: """
    A short noun phrase, 3 to 7 words, capturing the meeting's primary subject. \
    Never a full sentence. Never a question. Never starts with filler words like \
    'um', 'uh', 'yeah', 'so', 'ok', 'well', 'and', 'but'. No trailing period, \
    exclamation, or question mark. Capitalize like a headline. Examples: \
    'Q3 sales pipeline review', 'Onboarding flow redesign', 'Hiring plan for backend'.
    """)
    var title: String

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
    static let empty = MeetingSummary(title: "", decisions: [], actionItems: [], topics: [], openQuestions: [])

    var isEmpty: Bool {
        title.isEmpty && decisions.isEmpty && actionItems.isEmpty && topics.isEmpty && openQuestions.isEmpty
    }
}
