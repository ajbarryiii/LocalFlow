import Foundation

enum DictationProtocolTests {
    static var tests: [TestCase] {
        [
            ("constantsMatchContract", testConstantsMatchContract),
            ("recordsRoundTripThroughJSON", testRecordsRoundTripThroughJSON),
            ("wireFormatUsesSortedKeysAndUnixSeconds", testWireFormatUsesSortedKeysAndUnixSeconds),
            ("newRecordsUseCurrentSchema", testNewRecordsUseCurrentSchema),
            ("missingSchemaFailsToDecode", testMissingSchemaFailsToDecode),
            ("freshnessToleratesSmallSkewOnly", testFreshnessToleratesSmallSkewOnly),
            ("terminalPhases", testTerminalPhases),
            ("storeReadAccessors", testStoreReadAccessors),
        ]
    }

    private static func testConstantsMatchContract() {
        TestSupport.expectEqual(DictationProtocol.schema, 1)
        TestSupport.expectEqual(DictationProtocol.heartbeatInterval, 1)
        TestSupport.expectEqual(DictationProtocol.livenessTimeout, 3)
        TestSupport.expectEqual(DictationProtocol.clockSkewTolerance, 2)
        TestSupport.expectEqual(DictationProtocol.pendingRecordTTL, 20)
        TestSupport.expectEqual(DictationProtocol.startupTimeout, 10)
        TestSupport.expectEqual(DictationProtocol.captureFreshness, 1)
        TestSupport.expectEqual(DictationProtocol.keyboardPresenceInterval, 1)
        TestSupport.expectEqual(DictationProtocol.keyboardPresenceTimeout, 15)
        TestSupport.expectEqual(DictationProtocol.maxDictationDuration, 300)
        TestSupport.expectEqual(DictationProtocol.resultTTL, 60)
    }

    private static func roundTrip<T: Codable & Equatable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        TestSupport.expectEqual(try! decoder.decode(T.self, from: try! encoder.encode(value)), value)
    }

    private static func testRecordsRoundTripThroughJSON() {
        for action in [KeyboardIntent.Action.record, .finish, .cancel] { roundTrip(Fixture.intent(action)) }
        roundTrip(Fixture.presence())
        roundTrip(Fixture.status(.inactive, captureReady: false))
        roundTrip(Fixture.status(.starting, error: .microphonePermissionDenied))
        for phase in [DictationStatus.Phase.starting, .recording, .transcribing, .completed, .failed, .cancelled] {
            roundTrip(Fixture.status(dictation: Fixture.dictation(phase, error: .superseded), level: 0.25, error: .tooLong))
        }
        let codes: [HostErrorCode] = [
            .microphonePermissionDenied, .audioSessionFailed, .startupTimeout, .interrupted, .deviceLocked,
            .keyboardDismissed, .sessionInactive, .modelUnavailable, .modelFailed, .transcriptionFailed,
            .backgroundTimeExpired, .notRecording, .tooLong, .superseded,
        ]
        for code in codes { roundTrip(Fixture.dictation(.failed, error: code)) }
        var bare = Fixture.status()
        bare.sessionID = nil
        bare.sessionExpiresAt = nil
        roundTrip(bare)
        roundTrip(Fixture.result(text: "Synthetic \"quoted\" text with émoji 🎙️\nand a newline", pressEnter: true))
        roundTrip(Fixture.result(text: ""))
    }

    private static func testWireFormatUsesSortedKeysAndUnixSeconds() {
        let directory = TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SharedDictationStore(directory: directory)
        try! store.writeIntent(Fixture.intent(.record))
        let json = String(data: try! Data(contentsOf: store.intentURL), encoding: .utf8)!
        let keys = ["action", "issuedAt", "keyboardInstanceID", "requestID", "schema"]
        let offsets = keys.map { json.range(of: "\"\($0)\"")!.lowerBound }
        TestSupport.expectEqual(offsets, offsets.sorted())
        let object = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        TestSupport.expectEqual(object["issuedAt"] as? Double, 1_800_000_000)
        TestSupport.expectEqual(object["schema"] as? Int, 1)
        TestSupport.expectEqual(object["action"] as? String, "record")
    }

    private static func testNewRecordsUseCurrentSchema() {
        TestSupport.expectEqual(Fixture.intent(.record).schema, DictationProtocol.schema)
        TestSupport.expectEqual(Fixture.presence().schema, DictationProtocol.schema)
        TestSupport.expectEqual(Fixture.status().schema, DictationProtocol.schema)
        TestSupport.expectEqual(Fixture.result().schema, DictationProtocol.schema)
    }

    private static func testMissingSchemaFailsToDecode() {
        let json = #"{"action":"record","issuedAt":1800000000,"keyboardInstanceID":"00000000-0000-4000-8000-0000000000A1","requestID":"00000000-0000-4000-8000-000000000001"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        TestSupport.expect((try? decoder.decode(KeyboardIntent.self, from: Data(json.utf8))) == nil,
                           "decoded an intent without a schema")
    }

    private static func testFreshnessToleratesSmallSkewOnly() {
        let stamp = Fixture.now
        func fresh(_ age: TimeInterval) -> Bool { DictationProtocol.isFresh(stamp, ttl: 3, now: stamp + age) }
        TestSupport.expect(fresh(0), "age 0")
        TestSupport.expect(fresh(3), "age at the TTL")
        TestSupport.expect(!fresh(3.001), "age past the TTL")
        TestSupport.expect(fresh(-2), "stamp at the skew tolerance ahead of now")
        TestSupport.expect(!fresh(-2.001), "stamp beyond the skew tolerance: a backward clock jump fails closed")
        TestSupport.expect(!fresh(-3_600), "stamp an hour ahead of now")
    }

    private static func testTerminalPhases() {
        let terminal = [DictationStatus.Phase.starting, .recording, .transcribing, .completed, .failed, .cancelled]
            .filter(\.isTerminal)
        TestSupport.expectEqual(terminal, [.completed, .failed, .cancelled])
    }

    private static func testStoreReadAccessors() {
        TestSupport.expectEqual(StoreRead.value(7).value, 7)
        TestSupport.expectEqual(StoreRead<Int>.absent.value, nil)
        TestSupport.expectEqual(StoreRead<Int>.unreadable.value, nil)
        TestSupport.expectEqual(StoreRead<Int>.incompatible.value, nil)
        TestSupport.expect(StoreRead<Int>.incompatible.isIncompatible, "incompatible")
        TestSupport.expect(!StoreRead<Int>.unreadable.isIncompatible, "unreadable is not incompatible")
        TestSupport.expect(!StoreRead.value(7).isIncompatible, "a value is not incompatible")
    }
}
