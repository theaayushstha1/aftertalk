import Foundation
import SwiftData

@Model
final class MeetingSummaryRecord {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    var decisions: [String]
    var actionItemsJSON: Data
    var topics: [String]
    var openQuestions: [String]
    var generatedAt: Date
    var generationLatencyMillis: Double

    init(
        id: UUID = UUID(),
        decisions: [String] = [],
        actionItems: [ActionItemRecord] = [],
        topics: [String] = [],
        openQuestions: [String] = [],
        generatedAt: Date = .now,
        generationLatencyMillis: Double = 0
    ) {
        self.id = id
        self.decisions = decisions
        self.actionItemsJSON = (try? JSONEncoder().encode(actionItems)) ?? Data()
        self.topics = topics
        self.openQuestions = openQuestions
        self.generatedAt = generatedAt
        self.generationLatencyMillis = generationLatencyMillis
    }

    var actionItems: [ActionItemRecord] {
        get { (try? JSONDecoder().decode([ActionItemRecord].self, from: actionItemsJSON)) ?? [] }
        set { actionItemsJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

struct ActionItemRecord: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var description: String
    var owner: String?
}
