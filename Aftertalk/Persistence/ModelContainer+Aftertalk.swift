import Foundation
import SwiftData

enum AftertalkPersistence {
    static let schema = Schema([
        Meeting.self,
        MeetingSummaryRecord.self,
        TranscriptChunk.self,
        SpeakerLabel.self,
        MeetingSummaryEmbedding.self,
        ChatThread.self,
        ChatMessage.self,
    ])

    static func makeContainer() -> ModelContainer {
        let config = ModelConfiguration(
            "Aftertalk",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            assertionFailure("ModelContainer init failed: \(error)")
            let memory = ModelConfiguration("AftertalkInMemory", schema: schema, isStoredInMemoryOnly: true)
            // swiftlint:disable:next force_try
            return try! ModelContainer(for: schema, configurations: [memory])
        }
    }
}
