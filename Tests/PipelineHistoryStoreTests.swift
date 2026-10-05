import Foundation

enum PipelineHistoryStoreTests {
    static func run() {
        let store = PipelineHistoryStore(inMemory: true)
        let earlier = PipelineHistoryItem(timestamp: Date(timeIntervalSince1970: 1), rawTranscript: "Synthetic first", transcript: "", status: "Local", audioFileName: "first.wav")
        var later = PipelineHistoryItem(timestamp: Date(timeIntervalSince1970: 2), rawTranscript: "Synthetic second", transcript: "Synthetic macro", status: "Local", audioFileName: "second.wav")
        TestSupport.expectEqual(try! store.append(earlier, maxCount: 2), [])
        TestSupport.expectEqual(try! store.append(later, maxCount: 2), [])
        TestSupport.expectEqual(store.loadAllHistory().map(\.displayTranscript), ["Synthetic macro", "Synthetic first"])
        later.rawTranscript = "Synthetic retry"
        later.transcript = "Synthetic retry output"
        later.status = "Local (retried)"
        try! store.update(later)
        TestSupport.expectEqual(store.loadAllHistory().first?.transcript, "Synthetic retry output")
        TestSupport.expectEqual(store.loadAllHistory().first?.audioFileName, "second.wav")
        TestSupport.expectEqual(try! store.trim(to: 1), ["first.wav"])
        TestSupport.expectEqual(try! store.delete(id: later.id), "second.wav")
        TestSupport.expectEqual(store.loadAllHistory().count, 0)
    }
}
