import CoreData
import Foundation

enum PipelineHistoryStoreTests {
    static func run() {
        inMemoryStoreKeepsHistory()
        legacyStoreKeepsItsHistory(closedCleanly: true)
        legacyStoreKeepsItsHistory(closedCleanly: false)
        freshStoreKeepsHistory()
    }

    private static func inMemoryStoreKeepsHistory() {
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

    /// A Run Log written by LocalFlow 2.1.0–2.1.8 opens with every row intact and
    /// without FreeFlow's legacy attributes; opening it again changes nothing.
    /// `closedCleanly: false` copies the files of a store that is still open,
    /// as an app that quits or crashes leaves them, so recent rows live only in -wal.
    private static func legacyStoreKeepsItsHistory(closedCleanly: Bool) {
        withTemporaryDirectory { directory in
            let storeURL = directory.appendingPathComponent("PipelineHistory.sqlite")
            if closedCleanly {
                writeLegacyStore(at: storeURL)
                TestSupport.expect(storeSchema(at: storeURL) == .legacy, "fixture should be a legacy store")
            } else {
                // Not read before the store opens it: closing a reader could checkpoint the -wal.
                withTemporaryDirectory { source in
                    writeLegacyStore(at: source.appendingPathComponent("PipelineHistory.sqlite"), copyingOpenFilesTo: storeURL)
                }
            }

            autoreleasepool {
                let store = PipelineHistoryStore(storeURL: storeURL)
                TestSupport.expectEqual(store.loadAllHistory().map(Row.init), legacyRows.map(Row.init))
            }
            TestSupport.expect(storeSchema(at: storeURL) == .current, "legacy attributes should be gone from the store")
            TestSupport.expectEqual(storeFileNames(in: directory).subtracting(sqliteFileNames), [])
            let migratedStoreID = storeID(at: storeURL)

            let added = PipelineHistoryItem(timestamp: Date(timeIntervalSince1970: 1_800_000_000), rawTranscript: "Synthetic after update", transcript: "", status: "Local", audioFileName: "after-update.wav")
            autoreleasepool {
                let reopened = PipelineHistoryStore(storeURL: storeURL)
                TestSupport.expectEqual(reopened.loadAllHistory().map(Row.init), legacyRows.map(Row.init))
                TestSupport.expectEqual(try! reopened.append(added, maxCount: 20), [])
            }
            autoreleasepool {
                let reopened = PipelineHistoryStore(storeURL: storeURL)
                TestSupport.expectEqual(reopened.loadAllHistory().map(Row.init), ([added] + legacyRows).map(Row.init))
            }
            TestSupport.expect(storeSchema(at: storeURL) == .current, "reopened store should keep the current schema")
            TestSupport.expectEqual(storeID(at: storeURL), migratedStoreID)
            TestSupport.expectEqual(storeFileNames(in: directory).subtracting(sqliteFileNames), [])
        }
    }

    private static func freshStoreKeepsHistory() {
        withTemporaryDirectory { directory in
            let storeURL = directory.appendingPathComponent("New", isDirectory: true).appendingPathComponent("PipelineHistory.sqlite")
            let item = PipelineHistoryItem(timestamp: Date(timeIntervalSince1970: 1_750_000_000), rawTranscript: "Synthetic fresh", transcript: "Synthetic fresh output", status: "Local", audioFileName: nil)
            autoreleasepool {
                let store = PipelineHistoryStore(storeURL: storeURL)
                TestSupport.expectEqual(store.loadAllHistory().count, 0)
                TestSupport.expectEqual(try! store.append(item, maxCount: 20), [])
            }
            autoreleasepool {
                let reopened = PipelineHistoryStore(storeURL: storeURL)
                TestSupport.expectEqual(reopened.loadAllHistory().map(Row.init), [Row(item)])
            }
            TestSupport.expect(storeSchema(at: storeURL) == .current, "a new store should use the current schema")
        }
    }

    // MARK: - Fixtures

    private struct Row: Equatable {
        let id: UUID
        let timestamp: Date
        let rawTranscript: String
        let transcript: String
        let status: String
        let audioFileName: String?

        init(_ item: PipelineHistoryItem) {
            id = item.id
            timestamp = item.timestamp
            rawTranscript = item.rawTranscript
            transcript = item.transcript
            status = item.status
            audioFileName = item.audioFileName
        }
    }

    /// Newest first, the order `loadAllHistory` returns.
    private static let legacyRows: [PipelineHistoryItem] = [
        PipelineHistoryItem(id: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!, timestamp: Date(timeIntervalSince1970: 1_700_000_300), rawTranscript: "Synthetic third raw", transcript: "Synthetic third output", status: "Local (retried)", audioFileName: "synthetic-third.wav"),
        PipelineHistoryItem(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!, timestamp: Date(timeIntervalSince1970: 1_700_000_200), rawTranscript: "", transcript: "", status: "Error: synthetic failure", audioFileName: nil),
        PipelineHistoryItem(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, timestamp: Date(timeIntervalSince1970: 1_700_000_100), rawTranscript: "Synthetic first raw", transcript: "", status: "Local", audioFileName: "synthetic-first.wav")
    ]

    private static let sqliteFileNames: Set<String> = ["PipelineHistory.sqlite", "PipelineHistory.sqlite-wal", "PipelineHistory.sqlite-shm"]

    private static let entityName = "PipelineHistoryEntry"

    /// The schema LocalFlow 2.1.0–2.1.8 shipped, in its original order and
    /// defined independently of the app, so the test pins what stores on disk hold.
    private static let legacyAttributes: [(name: String, type: NSAttributeType, isOptional: Bool)] = [
        ("intent", .stringAttributeType, true),
        ("selectedText", .stringAttributeType, true),
        ("capturedSelection", .stringAttributeType, true),
        ("id", .UUIDAttributeType, false),
        ("timestamp", .dateAttributeType, false),
        ("rawTranscript", .stringAttributeType, false),
        ("postProcessedTranscript", .stringAttributeType, false),
        ("postProcessingPrompt", .stringAttributeType, true),
        ("systemPrompt", .stringAttributeType, true),
        ("contextSummary", .stringAttributeType, false),
        ("contextSystemPrompt", .stringAttributeType, true),
        ("contextPrompt", .stringAttributeType, true),
        ("contextScreenshotDataURL", .stringAttributeType, true),
        ("contextScreenshotStatus", .stringAttributeType, false),
        ("postProcessingStatus", .stringAttributeType, false),
        ("debugStatus", .stringAttributeType, false),
        ("customVocabulary", .stringAttributeType, false),
        ("audioFileName", .stringAttributeType, true),
        ("contextAppName", .stringAttributeType, true),
        ("contextBundleIdentifier", .stringAttributeType, true),
        ("contextWindowTitle", .stringAttributeType, true)
    ]

    /// The attributes the Run Log reads; every other legacy attribute is dropped.
    private static let keptAttributeNames: Set<String> = ["id", "timestamp", "rawTranscript", "postProcessedTranscript", "postProcessingStatus", "audioFileName"]

    private static let legacyModel = makeModel(legacyAttributes)

    private static let currentModel = makeModel(legacyAttributes.filter { keptAttributeNames.contains($0.name) })

    private static func makeModel(_ attributes: [(name: String, type: NSAttributeType, isOptional: Bool)]) -> NSManagedObjectModel {
        let entity = NSEntityDescription()
        entity.name = entityName
        entity.properties = attributes.map { name, type, isOptional in
            let attribute = NSAttributeDescription()
            attribute.name = name
            attribute.attributeType = type
            attribute.isOptional = isOptional
            return attribute
        }
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }

    private enum StoreSchema: Equatable {
        case legacy, current, other
    }

    private static func storeSchema(at url: URL) -> StoreSchema {
        guard let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url) else { return .other }
        if currentModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) { return .current }
        if legacyModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) { return .legacy }
        return .other
    }

    private static func storeID(at url: URL) -> String? {
        let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: url)
        return metadata?[NSStoreUUIDKey] as? String
    }

    private static func storeFileNames(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    /// Writes `legacyRows`, with every legacy attribute filled, to a new legacy
    /// store. With `copyingOpenFilesTo`, copies the store's files there before
    /// closing it, leaving the copy's recent rows only in its -wal file.
    private static func writeLegacyStore(at url: URL, copyingOpenFilesTo copyURL: URL? = nil) {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: legacyModel)
        let store = try! coordinator.addPersistentStore(type: .sqlite, at: url)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.performAndWait {
            let entity = legacyModel.entitiesByName[entityName]!
            for item in legacyRows {
                let object = NSManagedObject(entity: entity, insertInto: context)
                object.setValue(item.id, forKey: "id")
                object.setValue(item.timestamp, forKey: "timestamp")
                object.setValue(item.rawTranscript, forKey: "rawTranscript")
                object.setValue(item.transcript, forKey: "postProcessedTranscript")
                object.setValue(item.status, forKey: "postProcessingStatus")
                object.setValue(item.audioFileName, forKey: "audioFileName")
                for attribute in legacyAttributes where !keptAttributeNames.contains(attribute.name) {
                    object.setValue("Synthetic \(attribute.name)", forKey: attribute.name)
                }
            }
            try! context.save()
        }
        if let copyURL {
            let fileManager = FileManager.default
            let wal = url.path + "-wal"
            let walSize = (try? fileManager.attributesOfItem(atPath: wal)[.size] as? Int) ?? 0
            TestSupport.expect(walSize > 0, "an open store should hold its recent rows in -wal")
            for suffix in ["", "-wal", "-shm"] where fileManager.fileExists(atPath: url.path + suffix) {
                try! fileManager.copyItem(atPath: url.path + suffix, toPath: copyURL.path + suffix)
            }
        }
        try! coordinator.remove(store)
    }

    private static func withTemporaryDirectory(_ body: (URL) -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LocalFlowTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        body(directory)
    }
}
