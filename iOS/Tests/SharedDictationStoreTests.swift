import Foundation

enum SharedDictationStoreTests {
    static var tests: [TestCase] {
        [
            ("directoryIsInGroupCaches", testDirectoryIsInGroupCaches),
            ("missingFilesReadAsAbsent", testMissingFilesReadAsAbsent),
            ("createsDirectoryExcludedFromBackup", testCreatesDirectoryExcludedFromBackup),
            ("writesAndReadsEveryRecord", testWritesAndReadsEveryRecord),
            ("overwriteReplacesAtomically", testOverwriteReplacesAtomically),
            ("unknownSchemaReadsAsIncompatible", testUnknownSchemaReadsAsIncompatible),
            ("corruptFilesReadAsUnreadable", testCorruptFilesReadAsUnreadable),
            ("resultMustMatchItsFileName", testResultMustMatchItsFileName),
            ("statusLevelIsSanitized", testStatusLevelIsSanitized),
            ("listsResultRequestIDs", testListsResultRequestIDs),
            ("deleteResultReportsWhoRemovedIt", testDeleteResultReportsWhoRemovedIt),
            ("purgeExpiredUsesCreatedAt", testPurgeExpiredUsesCreatedAt),
            ("purgeExpiredFallsBackToFileDate", testPurgeExpiredFallsBackToFileDate),
            ("purgeWherePassesEachOutcome", testPurgeWherePassesEachOutcome),
            ("readersNeverSeePartialRecords", testReadersNeverSeePartialRecords),
            ("abandonedStagingFilesAreSwept", testAbandonedStagingFilesAreSwept),
            ("failedWriteRemovesItsStagingFile", testFailedWriteRemovesItsStagingFile),
            ("removeResultReportsEachOutcome", testRemoveResultReportsEachOutcome),
            ("concurrentRemovalsHaveOneWinner", testConcurrentRemovalsHaveOneWinner),
            ("purgeRacingClaimantsRemovesOnce", testPurgeRacingClaimantsRemovesOnce),
        ]
    }

    private static func stagingNames(in store: SharedDictationStore) -> [String] {
        fileNames(in: store).filter { $0.hasPrefix(SharedDictationStore.stagingPrefix) }
    }

    /// Makes the store's directory read-only for `body`, so removing or creating files fails.
    static func withReadOnlyDirectory(of store: SharedDictationStore, _ body: () -> Void) {
        let path = store.directory.path
        try! FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
        defer { try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }
        body()
    }

    private static func withStore(_ body: (SharedDictationStore) -> Void) {
        let root = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        body(SharedDictationStore(directory: SharedDictationStore.directory(inContainer: root)))
    }

    private static func fileNames(in store: SharedDictationStore) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).sorted()
    }

    private static func put(_ text: String, at url: URL) {
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(text.utf8).write(to: url)
    }

    private static func setModificationDate(_ date: Date, of url: URL) {
        try! FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static func testDirectoryIsInGroupCaches() {
        let container = URL(fileURLWithPath: "/synthetic/container", isDirectory: true)
        TestSupport.expectEqual(SharedDictationStore.directory(inContainer: container).path,
                                "/synthetic/container/Library/Caches/LocalFlowDictation")
    }

    private static func testMissingFilesReadAsAbsent() {
        withStore { store in
            TestSupport.expectEqual(store.readIntent(), .absent)
            TestSupport.expectEqual(store.readPresence(), .absent)
            TestSupport.expectEqual(store.readStatus(), .absent)
            TestSupport.expectEqual(store.readResult(requestID: Fixture.requestID), .absent)
            TestSupport.expectEqual(store.resultRequestIDs(), [])
            TestSupport.expect(!store.deleteResult(requestID: Fixture.requestID), "deleted a missing result")
            store.purgeExpiredResults(now: Fixture.now)
            store.purgeResults { _, _ in true }
            TestSupport.expect(!FileManager.default.fileExists(atPath: store.directory.path), "reads created the directory")
        }
    }

    private static func testCreatesDirectoryExcludedFromBackup() {
        withStore { store in
            try! store.writePresence(Fixture.presence())
            TestSupport.expectEqual(fileNames(in: store), ["presence.json"])
            let values = try! store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            TestSupport.expectEqual(values.isExcludedFromBackup, true)
        }
    }

    private static func testWritesAndReadsEveryRecord() {
        withStore { store in
            let intent = Fixture.intent(.finish, instance: Fixture.otherInstanceID)
            let presence = Fixture.presence(seenAt: Fixture.now + 1)
            let status = Fixture.status(dictation: Fixture.dictation(.transcribing), level: 0.5, error: .interrupted)
            let result = Fixture.result(pressEnter: true)
            let other = Fixture.result(Fixture.otherRequestID, text: "Another synthetic line")
            try! store.writeIntent(intent)
            try! store.writePresence(presence)
            try! store.writeStatus(status)
            try! store.writeResult(result)
            try! store.writeResult(other)
            TestSupport.expectEqual(store.readIntent(), .value(intent))
            TestSupport.expectEqual(store.readPresence(), .value(presence))
            TestSupport.expectEqual(store.readStatus(), .value(status))
            TestSupport.expectEqual(store.readResult(requestID: Fixture.requestID), .value(result))
            TestSupport.expectEqual(store.readResult(requestID: Fixture.otherRequestID), .value(other))
            TestSupport.expectEqual(fileNames(in: store), [
                "intent.json", "presence.json", "result-\(Fixture.requestID.uuidString).json",
                "result-\(Fixture.otherRequestID.uuidString).json", "status.json",
            ])
        }
    }

    private static func testOverwriteReplacesAtomically() {
        withStore { store in
            for (index, action) in [KeyboardIntent.Action.record, .finish, .cancel].enumerated() {
                let intent = Fixture.intent(action, at: Fixture.now + Double(index))
                try! store.writeIntent(intent)
                TestSupport.expectEqual(store.readIntent(), .value(intent))
            }
            for phase in [DictationStatus.Phase.starting, .recording, .completed] {
                let status = Fixture.status(dictation: Fixture.dictation(phase))
                try! store.writeStatus(status)
                TestSupport.expectEqual(store.readStatus(), .value(status))
            }
            // The atomic write's temporary files never linger next to the records.
            TestSupport.expectEqual(fileNames(in: store), ["intent.json", "status.json"])
        }
    }

    private static func testUnknownSchemaReadsAsIncompatible() {
        withStore { store in
            var intent = Fixture.intent(.record)
            intent.schema = 2
            var presence = Fixture.presence()
            presence.schema = 0
            var status = Fixture.status()
            status.schema = 3
            var result = Fixture.result()
            result.schema = 99
            try! store.writeIntent(intent)
            try! store.writePresence(presence)
            try! store.writeStatus(status)
            try! store.writeResult(result)
            TestSupport.expectEqual(store.readIntent(), .incompatible)
            TestSupport.expectEqual(store.readPresence(), .incompatible)
            TestSupport.expectEqual(store.readStatus(), .incompatible)
            TestSupport.expectEqual(store.readResult(requestID: Fixture.requestID), .incompatible)

            // A future schema may change every other field; it is still incompatible, not corrupt.
            put(#"{"schema":2,"requestID":"not-a-uuid","shape":["new"]}"#, at: store.intentURL)
            TestSupport.expectEqual(store.readIntent(), .incompatible)
        }
    }

    private static func testCorruptFilesReadAsUnreadable() {
        withStore { store in
            for contents in ["", "{", "null", "[]", #"{"schema":"1"}"#, #"{"schema":1}"#, "\u{FFFD}garbage"] {
                for url in [store.intentURL, store.presenceURL, store.statusURL, store.resultURL(for: Fixture.requestID)] {
                    put(contents, at: url)
                }
                TestSupport.expectEqual(store.readIntent(), .unreadable)
                TestSupport.expectEqual(store.readPresence(), .unreadable)
                TestSupport.expectEqual(store.readStatus(), .unreadable)
                TestSupport.expectEqual(store.readResult(requestID: Fixture.requestID), .unreadable)
            }
            // An I/O error (here, a directory where the record should be) is unreadable, not absent.
            try! FileManager.default.removeItem(at: store.statusURL)
            try! FileManager.default.createDirectory(at: store.statusURL, withIntermediateDirectories: true)
            TestSupport.expectEqual(store.readStatus(), .unreadable)
        }
    }

    private static func testResultMustMatchItsFileName() {
        withStore { store in
            try! store.writeResult(Fixture.result(Fixture.otherRequestID))
            try! FileManager.default.moveItem(at: store.resultURL(for: Fixture.otherRequestID),
                                              to: store.resultURL(for: Fixture.requestID))
            TestSupport.expectEqual(store.readResult(requestID: Fixture.requestID), .unreadable)
            TestSupport.expectEqual(store.readResult(requestID: Fixture.otherRequestID), .absent)
        }
    }

    private static func testStatusLevelIsSanitized() {
        withStore { store in
            for (level, expected) in [(Float.nan, Float(0)), (.infinity, 0), (-0.5, 0), (1.5, 1), (0.25, 0.25)] {
                try! store.writeStatus(Fixture.status(level: level))
                TestSupport.expectEqual(store.readStatus().value?.level, expected)
            }
        }
    }

    private static func testListsResultRequestIDs() {
        withStore { store in
            try! store.writeIntent(Fixture.intent(.finish))
            try! store.writeResult(Fixture.result(Fixture.otherRequestID))
            try! store.writeResult(Fixture.result())
            let lowercase = UUID(uuidString: "00000000-0000-4000-8000-0000000000EE")!
            put("{", at: store.directory.appendingPathComponent("result-\(lowercase.uuidString.lowercased()).json"))
            put("unrelated", at: store.directory.appendingPathComponent("result-notes.json"))
            put("unrelated", at: store.directory.appendingPathComponent("result-\(Fixture.requestID.uuidString).txt"))
            TestSupport.expectEqual(Set(store.resultRequestIDs()), [Fixture.requestID, Fixture.otherRequestID, lowercase])
        }
    }

    private static func testDeleteResultReportsWhoRemovedIt() {
        withStore { store in
            try! store.writeResult(Fixture.result())
            try! store.writeResult(Fixture.result(Fixture.otherRequestID))
            let other = SharedDictationStore(directory: store.directory)   // the other process
            TestSupport.expect(store.deleteResult(requestID: Fixture.requestID), "first delete lost")
            TestSupport.expect(!other.deleteResult(requestID: Fixture.requestID), "second delete also won")
            TestSupport.expectEqual(store.readResult(requestID: Fixture.requestID), .absent)
            TestSupport.expectEqual(store.readResult(requestID: Fixture.otherRequestID).value?.requestID,
                                    Fixture.otherRequestID)
        }
    }

    private static func testPurgeExpiredUsesCreatedAt() {
        withStore { store in
            let ttl = DictationProtocol.resultTTL
            let tolerance = DictationProtocol.clockSkewTolerance
            let ids = (0..<5).map { UUID(uuidString: "00000000-0000-4000-8000-00000000010\($0)")! }
            try! store.writeIntent(Fixture.intent(.finish))
            try! store.writeStatus(Fixture.status())
            try! store.writeResult(Fixture.result(ids[0], createdAt: Fixture.now))                 // fresh
            try! store.writeResult(Fixture.result(ids[1], createdAt: Fixture.now - ttl))           // TTL boundary
            try! store.writeResult(Fixture.result(ids[2], createdAt: Fixture.now - ttl - 1))       // expired
            try! store.writeResult(Fixture.result(ids[3], createdAt: Fixture.now + tolerance))     // skew boundary
            try! store.writeResult(Fixture.result(ids[4], createdAt: Fixture.now + tolerance + 1)) // clock went back

            store.purgeExpiredResults(now: Fixture.now)

            TestSupport.expectEqual(Set(store.resultRequestIDs()), [ids[0], ids[1], ids[3]])
            TestSupport.expect(fileNames(in: store).contains("intent.json"), "purge removed the intent")
            TestSupport.expect(fileNames(in: store).contains("status.json"), "purge removed the status")
        }
    }

    /// A result protected while the device is locked, or written by another version, cannot be
    /// decoded; it is still deleted once its file is older than the TTL, and kept until then.
    private static func testPurgeExpiredFallsBackToFileDate() {
        withStore { store in
            let ttl = DictationProtocol.resultTTL
            var foreign = Fixture.result()
            foreign.schema = 2
            try! store.writeResult(foreign)
            put("{", at: store.resultURL(for: Fixture.otherRequestID))
            let now = Date()
            setModificationDate(now - 10, of: store.resultURL(for: Fixture.requestID))
            setModificationDate(now - 10, of: store.resultURL(for: Fixture.otherRequestID))
            store.purgeExpiredResults(now: now)
            TestSupport.expectEqual(Set(store.resultRequestIDs()), [Fixture.requestID, Fixture.otherRequestID])

            setModificationDate(now - ttl - 1, of: store.resultURL(for: Fixture.otherRequestID))
            store.purgeExpiredResults(now: now)
            TestSupport.expectEqual(store.resultRequestIDs(), [Fixture.requestID])
            store.purgeExpiredResults(now: now + ttl + 11)
            TestSupport.expectEqual(store.resultRequestIDs(), [])
        }
    }

    private static func testPurgeWherePassesEachOutcome() {
        withStore { store in
            let unreadable = UUID(uuidString: "00000000-0000-4000-8000-0000000000EF")!
            try! store.writeIntent(Fixture.intent(.record))
            try! store.writeStatus(Fixture.status())
            try! store.writeResult(Fixture.result())
            try! store.writeResult(Fixture.result(Fixture.otherRequestID, hostRunID: Fixture.otherHostRunID))
            put("{", at: store.resultURL(for: unreadable))
            var seen: [UUID: StoreRead<DictationResult>] = [:]
            store.purgeResults { id, read in
                seen[id] = read
                return false
            }
            TestSupport.expectEqual(seen.count, 3)
            TestSupport.expectEqual(seen[Fixture.requestID], .value(Fixture.result()))
            TestSupport.expectEqual(seen[unreadable], .unreadable)

            store.purgeResults { _, read in read.value?.hostRunID != Fixture.hostRunID }
            TestSupport.expectEqual(store.resultRequestIDs(), [Fixture.requestID])
            store.purgeResults { _, _ in true }
            TestSupport.expectEqual(fileNames(in: store), ["intent.json", "status.json"])
        }
    }

    /// A reader thread overlapping a writer thread's overwrites only ever decodes complete records
    /// that were written, in order, and never sees a staging file as a result.
    private static func testReadersNeverSeePartialRecords() {
        withStore { store in
            let count = 300
            let statuses = (0..<count).map { index in
                Fixture.status(heartbeatAt: Fixture.now + Double(index), dictation: Fixture.dictation(.recording),
                               level: Float(index % 10) / 10)
            }
            let intents = (0..<count).map { Fixture.intent(.record, at: Fixture.now + Double($0)) }
            let results = (0..<count).map { Fixture.result(text: "Synthetic line \($0)", createdAt: Fixture.now + Double($0)) }
            try! store.writeStatus(statuses[0])
            try! store.writeIntent(intents[0])
            try! store.writeResult(results[0])
            let finished = Locked(false)
            let reads = Locked(0)
            let failures = Locked<[String]>([])

            Concurrently.run(2) { thread in
                guard thread == 1 else {
                    for index in 1..<count {
                        try! store.writeStatus(statuses[index])
                        try! store.writeIntent(intents[index])
                        try! store.writeResult(results[index])
                    }
                    finished.update { $0 = true }
                    return
                }
                var last = (status: 0, intent: 0, result: 0)
                func check(_ position: Int?, after previous: inout Int, _ label: String) {
                    guard let position, position >= previous else {
                        failures.update { $0.append("\(label) read \(String(describing: position)) after \(previous)") }
                        return
                    }
                    previous = position
                }
                while !finished.current {
                    let status = store.readStatus().value
                    let statusIndex = status.flatMap { value in statuses.firstIndex { $0 == value } }
                    check(statusIndex, after: &last.status, "status")
                    let intent = store.readIntent().value
                    check(intent.flatMap { value in intents.firstIndex { $0 == value } }, after: &last.intent, "intent")
                    let result = store.readResult(requestID: Fixture.requestID).value
                    check(result.flatMap { value in results.firstIndex { $0 == value } }, after: &last.result, "result")
                    if store.resultRequestIDs() != [Fixture.requestID] {
                        failures.update { $0.append("listed \(store.resultRequestIDs())") }
                    }
                    reads.update { $0 += 1 }
                }
            }

            TestSupport.expectEqual(failures.current, [])
            TestSupport.expect(reads.current > 0, "the reader never overlapped the writer")
            TestSupport.expectEqual(store.readStatus(), .value(statuses[count - 1]))
            TestSupport.expectEqual(stagingNames(in: store), [])
        }
    }

    /// A writer that dies between writing and renaming leaves a staging file. Readers never see it,
    /// either process's expiry purge removes it once it is as old as a result could be, and the host's
    /// run recovery removes it at any age.
    private static func testAbandonedStagingFilesAreSwept() {
        withStore { store in
            let ttl = DictationProtocol.resultTTL
            try! store.writeIntent(Fixture.intent(.finish))
            try! store.writeStatus(Fixture.status())
            try! store.writeResult(Fixture.result())
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let transcript = try! encoder.encode(Fixture.result(Fixture.otherRequestID))
            func stage(modifiedAgo age: TimeInterval) -> String {
                let name = "\(SharedDictationStore.stagingPrefix)\(UUID().uuidString)\(SharedDictationStore.stagingSuffix)"
                let url = store.directory.appendingPathComponent(name, isDirectory: false)
                try! transcript.write(to: url)
                setModificationDate(Fixture.now - age, of: url)
                return name
            }
            _ = stage(modifiedAgo: ttl + 1)                                      // abandoned
            _ = stage(modifiedAgo: -DictationProtocol.clockSkewTolerance - 1)    // the clock went back
            let inFlight = stage(modifiedAgo: 1)                                 // possibly another process's write
            TestSupport.expectEqual(store.resultRequestIDs(), [Fixture.requestID])
            TestSupport.expectEqual(store.readResult(requestID: Fixture.otherRequestID), .absent)

            store.purgeExpiredResults(now: Fixture.now)
            TestSupport.expectEqual(stagingNames(in: store), [inFlight])
            store.purgeStagingFiles(olderThan: ttl, now: Fixture.now)
            TestSupport.expectEqual(stagingNames(in: store), [inFlight])

            store.purgeStagingFiles(olderThan: 0, now: Fixture.now)
            TestSupport.expectEqual(fileNames(in: store),
                                    ["intent.json", "result-\(Fixture.requestID.uuidString).json", "status.json"])
            TestSupport.expectEqual(store.readResult(requestID: Fixture.requestID), .value(Fixture.result()))
        }
    }

    private static func testFailedWriteRemovesItsStagingFile() {
        withStore { store in
            try! store.writeIntent(Fixture.intent(.record))
            // A directory where status.json belongs makes the rename fail after the staging write.
            try! FileManager.default.createDirectory(at: store.statusURL.appendingPathComponent("occupied"),
                                                    withIntermediateDirectories: true)
            TestSupport.expect((try? store.writeStatus(Fixture.status())) == nil, "renamed over a directory")
            TestSupport.expectEqual(stagingNames(in: store), [])
            // A write that cannot create its staging file fails cleanly too, leaving the old record.
            withReadOnlyDirectory(of: store) {
                TestSupport.expect((try? store.writeIntent(Fixture.intent(.cancel))) == nil, "wrote into a read-only directory")
            }
            TestSupport.expectEqual(store.readIntent(), .value(Fixture.intent(.record)))
            TestSupport.expectEqual(stagingNames(in: store), [])
        }
    }

    private static func testRemoveResultReportsEachOutcome() {
        withStore { store in
            try! store.writeResult(Fixture.result())
            withReadOnlyDirectory(of: store) {
                TestSupport.expectEqual(store.removeResult(requestID: Fixture.requestID), .failed)
                TestSupport.expect(!store.deleteResult(requestID: Fixture.requestID), "a failed removal reported success")
            }
            TestSupport.expectEqual(store.readResult(requestID: Fixture.requestID), .value(Fixture.result()))
            TestSupport.expectEqual(store.removeResult(requestID: Fixture.requestID), .removed)
            TestSupport.expectEqual(store.removeResult(requestID: Fixture.requestID), .alreadyAbsent)
            let missing = SharedDictationStore(directory: store.directory.appendingPathComponent("missing"))
            TestSupport.expectEqual(missing.removeResult(requestID: Fixture.requestID), .alreadyAbsent)
        }
    }

    /// Regression: on APFS, concurrent unlinks of one name all report success, which made two
    /// claimants both win. Racing removals through two stores (as two processes would) must
    /// produce exactly one `.removed`.
    private static func testConcurrentRemovalsHaveOneWinner() {
        withStore { store in
            let otherProcess = SharedDictationStore(directory: store.directory)
            for iteration in 0..<200 {
                let requestID = UUID()
                try! store.writeResult(Fixture.result(requestID))
                let outcomes = Locked<[SharedDictationStore.ResultRemoval]>([])
                Concurrently.run(3) { thread in
                    let outcome = (thread == 0 ? otherProcess : store).removeResult(requestID: requestID)
                    outcomes.update { $0.append(outcome) }
                }
                let sorted = outcomes.current.map { "\($0)" }.sorted()
                TestSupport.expect(sorted == ["alreadyAbsent", "alreadyAbsent", "removed"],
                                   "iteration \(iteration): \(sorted)")
            }
            TestSupport.expectEqual(fileNames(in: store), [])
        }
    }

    /// The host's purge takes the same path as a claim, so a purge racing claimants never lets a
    /// claimant win a result the purge also removed.
    private static func testPurgeRacingClaimantsRemovesOnce() {
        withStore { store in
            for _ in 0..<200 {
                let requestID = UUID()
                try! store.writeResult(Fixture.result(requestID, createdAt: Fixture.now - DictationProtocol.resultTTL - 1))
                let removed = Locked(0)
                Concurrently.run(3) { thread in
                    if thread == 0 {
                        store.purgeExpiredResults(now: Fixture.now)
                    } else if store.removeResult(requestID: requestID) == .removed {
                        removed.update { $0 += 1 }
                    }
                }
                TestSupport.expect(removed.current <= 1, "\(removed.current) claimants won one result")
                TestSupport.expectEqual(store.readResult(requestID: requestID), .absent)
            }
            TestSupport.expectEqual(stagingNames(in: store), [])
        }
    }
}
