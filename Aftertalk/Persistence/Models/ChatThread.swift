import Foundation
import SwiftData

@Model
final class ChatThread {
    @Attribute(.unique) var id: UUID
    var meeting: Meeting?
    var meetingId: UUID?
    var isGlobal: Bool
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.thread)
    var messages: [ChatMessage] = []

    init(id: UUID = UUID(), meetingId: UUID? = nil, isGlobal: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.meetingId = meetingId
        self.isGlobal = isGlobal
        self.createdAt = createdAt
    }
}

@Model
final class ChatMessage {
    @Attribute(.unique) var id: UUID
    var thread: ChatThread?
    var role: String
    var text: String
    var audioPath: String?
    var timestamp: Date
    var citationsJSON: Data

    init(
        id: UUID = UUID(),
        role: String,
        text: String,
        audioPath: String? = nil,
        timestamp: Date = .now,
        citations: [ChunkCitation] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.audioPath = audioPath
        self.timestamp = timestamp
        self.citationsJSON = (try? JSONEncoder().encode(citations)) ?? Data()
    }

    var citations: [ChunkCitation] {
        get { (try? JSONDecoder().decode([ChunkCitation].self, from: citationsJSON)) ?? [] }
        set { citationsJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
}

struct ChunkCitation: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var chunkId: UUID
    var meetingId: UUID
    var startSec: Double
    var endSec: Double
    var speakerName: String?
}
