import Foundation
import CoreData

final class PipelineHistoryStore {
    private let container: NSPersistentContainer
    private let isStoreLoaded: Bool

    convenience init(inMemory: Bool = false) {
        self.init(storeURL: inMemory ? nil : Self.defaultStoreURL())
    }

    /// Opens the SQLite store at `storeURL`, creating it if needed; `nil` keeps history in memory.
    init(storeURL: URL?) {
        container = NSPersistentContainer(name: "PipelineHistory", managedObjectModel: Self.model)
        guard let storeURL else {
            isStoreLoaded = Self.loadInMemoryStore(into: container)
            return
        }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        do {
            try Self.migrateLegacyStoreIfNeeded(at: storeURL)
        } catch {
            // Leave the old store for the next launch instead of letting the recovery below delete it.
            print("[PipelineHistoryStore] Could not update the history store (\((error as NSError).domain) \((error as NSError).code)). Using in-memory history.")
            isStoreLoaded = Self.loadInMemoryStore(into: container)
            return
        }

        container.persistentStoreDescriptions = [Self.sqliteDescription(at: storeURL)]
        if Self.loadPersistentStoresSynchronously(container: container) == nil {
            isStoreLoaded = true
            return
        }

        print("[PipelineHistoryStore] Failed to load persistent store at \(storeURL.path). Attempting recovery.")
        Self.destroySQLiteStoreFiles(at: storeURL)
        // Clear any partially loaded stores and reset descriptions before retrying.
        Self.removeLoadedStores(from: container)
        container.persistentStoreDescriptions = [Self.sqliteDescription(at: storeURL)]
        if Self.loadPersistentStoresSynchronously(container: container) == nil {
            isStoreLoaded = true
        } else {
            print("[PipelineHistoryStore] Failed to recover persistent store. Falling back to in-memory history.")
            isStoreLoaded = Self.loadInMemoryStore(into: container)
        }
    }

    func loadAllHistory() -> [PipelineHistoryItem] {
        guard isStoreLoaded else { return [] }
        var result: [PipelineHistoryItem] = []
        container.viewContext.performAndWait {
            let request = pipelineHistoryRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
            guard let entities = try? container.viewContext.fetch(request) else { return }
            result = entities.compactMap(Self.makeHistoryItem(from:))
        }
        return result
    }

    func append(_ item: PipelineHistoryItem, maxCount: Int) throws -> [String] {
        guard isStoreLoaded else { return [] }
        try insert(item)
        return try trim(to: maxCount)
    }

    func update(_ item: PipelineHistoryItem) throws {
        guard isStoreLoaded else { return }

        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.predicate = NSPredicate(format: "id == %@", item.id as CVarArg)
                guard let entity = try container.viewContext.fetch(request).first else { return }
                entity.rawTranscript = item.rawTranscript
                entity.postProcessedTranscript = item.transcript
                entity.postProcessingStatus = item.status
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
    }

    func delete(id: UUID) throws -> String? {
        guard isStoreLoaded else { return nil }

        var deletedAudioFileName: String?
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
                guard let entity = try container.viewContext.fetch(request).first else { return }
                deletedAudioFileName = entity.audioFileName
                container.viewContext.delete(entity)
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        return deletedAudioFileName
    }

    func clearAll() throws -> [String] {
        guard isStoreLoaded else { return [] }

        var audioFileNames: [String] = []
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                guard let entities = try? container.viewContext.fetch(request) else { return }
                audioFileNames = entities.compactMap(\.audioFileName)
                for entity in entities {
                    container.viewContext.delete(entity)
                }
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        return audioFileNames
    }

    func trim(to maxCount: Int) throws -> [String] {
        guard isStoreLoaded else { return [] }
        guard maxCount > 0 else {
            let audioFileNames = try clearAll()
            return audioFileNames
        }

        var audioFileNames: [String] = []
        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let request = pipelineHistoryRequest()
                request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
                guard let entities = try? container.viewContext.fetch(request), entities.count > maxCount else { return }
                let dropped = entities[maxCount...]
                audioFileNames = dropped.compactMap(\.audioFileName)
                for entity in dropped {
                    container.viewContext.delete(entity)
                }
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
        return audioFileNames
    }

    private func insert(_ item: PipelineHistoryItem) throws {
        guard isStoreLoaded else { return }

        var thrownError: Error?
        container.viewContext.performAndWait {
            do {
                let context = container.viewContext
                let entity = PipelineHistoryEntry(context: context)
                entity.id = item.id
                entity.timestamp = item.timestamp
                entity.rawTranscript = item.rawTranscript
                entity.postProcessedTranscript = item.transcript
                entity.postProcessingStatus = item.status
                entity.audioFileName = item.audioFileName
                try saveContext()
            } catch {
                thrownError = error
            }
        }
        if let thrownError { throw thrownError }
    }

    private func saveContext() throws {
        guard container.viewContext.hasChanges else { return }
        do {
            try container.viewContext.save()
        } catch {
            container.viewContext.rollback()
            throw error
        }
    }

    private func pipelineHistoryRequest() -> NSFetchRequest<PipelineHistoryEntry> {
        NSFetchRequest<PipelineHistoryEntry>(entityName: "PipelineHistoryEntry")
    }

    // Safe: loadPersistentStores calls back on a private queue, not the calling thread.
    private static func loadPersistentStoresSynchronously(container: NSPersistentContainer) -> Error? {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var capturedError: Error?
        var remainingCompletions = max(1, container.persistentStoreDescriptions.count)

        container.loadPersistentStores { _, error in
            lock.lock()
            if capturedError == nil, let error {
                capturedError = error
            }
            remainingCompletions -= 1
            let shouldSignal = remainingCompletions <= 0
            lock.unlock()

            if shouldSignal {
                semaphore.signal()
            }
        }

        semaphore.wait()
        return capturedError
    }

    private static func loadInMemoryStore(into container: NSPersistentContainer) -> Bool {
        removeLoadedStores(from: container)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        return loadPersistentStoresSynchronously(container: container) == nil
    }

    private static func removeLoadedStores(from container: NSPersistentContainer) {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }

    private static func sqliteDescription(at storeURL: URL) -> NSPersistentStoreDescription {
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        return description
    }

    private static func defaultStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport
            .appendingPathComponent(AppName.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("PipelineHistory.sqlite")
    }

    /// Rewrites a store from LocalFlow 2.1.0–2.1.8 without FreeFlow's legacy
    /// attributes. Core Data cannot do this on its own: a model built in code
    /// leaves it no source model to infer from, so the load would fail and the
    /// recovery in `init` would delete the history. The old store stays as it
    /// was until the migrated copy replaces it, so an interrupted migration runs
    /// again on the next launch.
    private static func migrateLegacyStoreIfNeeded(at storeURL: URL) throws {
        let stagingURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.deletingPathExtension().lastPathComponent + "-migrating.sqlite")
        destroySQLiteStoreFiles(at: stagingURL)
        guard FileManager.default.fileExists(atPath: storeURL.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(type: .sqlite, at: storeURL),
              !model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata),
              legacyModel.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata)
        else { return }

        defer { destroySQLiteStoreFiles(at: stagingURL) }
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: legacyModel, destinationModel: model)
        try NSMigrationManager(sourceModel: legacyModel, destinationModel: model)
            .migrateStore(from: storeURL, type: .sqlite, mapping: mapping, to: stagingURL, type: .sqlite)
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator.replacePersistentStore(at: storeURL, withPersistentStoreFrom: stagingURL, type: .sqlite)
        try? coordinator.destroyPersistentStore(at: stagingURL, type: .sqlite)
    }

    private static func destroySQLiteStoreFiles(at storeURL: URL) {
        let basePath = storeURL.path
        let fileManager = FileManager.default
        for path in [basePath, basePath + "-wal", basePath + "-shm"] {
            try? fileManager.removeItem(atPath: path)
        }
    }

    private static func makeHistoryItem(from entity: PipelineHistoryEntry) -> PipelineHistoryItem {
        PipelineHistoryItem(id: entity.id, timestamp: entity.timestamp ?? Date(),
                            rawTranscript: entity.rawTranscript ?? "",
                            transcript: entity.postProcessedTranscript ?? "",
                            status: entity.postProcessingStatus ?? "", audioFileName: entity.audioFileName)
    }

    /// One shared model, so every store maps `PipelineHistoryEntry` to the same entity.
    private static let model: NSManagedObjectModel = {
        let entity = NSEntityDescription()
        entity.name = "PipelineHistoryEntry"
        entity.managedObjectClassName = NSStringFromClass(PipelineHistoryEntry.self)
        entity.properties = [
            makeAttribute(name: "id", type: .UUIDAttributeType, isOptional: false),
            makeAttribute(name: "timestamp", type: .dateAttributeType, isOptional: false),
            makeAttribute(name: "rawTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessedTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessingStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "audioFileName", type: .stringAttributeType, isOptional: true)
        ]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }()

    /// The schema LocalFlow 2.1.0–2.1.8 kept verbatim from FreeFlow, with
    /// context, prompt and screenshot attributes the app never read. Only the
    /// migration uses it, as its source model.
    private static let legacyModel: NSManagedObjectModel = {
        let entity = NSEntityDescription()
        entity.name = "PipelineHistoryEntry"
        entity.properties = [
            makeAttribute(name: "intent", type: .stringAttributeType, isOptional: true, defaultValue: "dictation"),
            makeAttribute(name: "selectedText", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "capturedSelection", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "id", type: .UUIDAttributeType, isOptional: false),
            makeAttribute(name: "timestamp", type: .dateAttributeType, isOptional: false),
            makeAttribute(name: "rawTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessedTranscript", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessingPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "systemPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextSummary", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "contextSystemPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextPrompt", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextScreenshotDataURL", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextScreenshotStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "postProcessingStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "debugStatus", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "customVocabulary", type: .stringAttributeType, isOptional: false),
            makeAttribute(name: "audioFileName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextAppName", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextBundleIdentifier", type: .stringAttributeType, isOptional: true),
            makeAttribute(name: "contextWindowTitle", type: .stringAttributeType, isOptional: true)
        ]
        let model = NSManagedObjectModel()
        model.entities = [entity]
        return model
    }()

    private static func makeAttribute(
        name: String,
        type: NSAttributeType,
        isOptional: Bool,
        defaultValue: Any? = nil
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = isOptional
        attribute.defaultValue = defaultValue
        return attribute
    }
}

@objc(PipelineHistoryEntry)
final class PipelineHistoryEntry: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var timestamp: Date?
    @NSManaged var rawTranscript: String?
    @NSManaged var postProcessedTranscript: String?
    @NSManaged var postProcessingStatus: String?
    @NSManaged var audioFileName: String?
}
