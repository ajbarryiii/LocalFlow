import Foundation

struct PipelineHistoryItem: Identifiable, Codable {
    var id: UUID = UUID()
    var timestamp: Date
    var rawTranscript: String
    var transcript: String
    var status: String
    var audioFileName: String?

    var displayTranscript: String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? rawTranscript : transcript
    }
}
