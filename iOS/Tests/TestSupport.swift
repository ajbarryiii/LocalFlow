import Foundation

typealias TestCase = (name: String, run: () -> Void)

enum TestSupport {
    static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else {
            fatalError("\(file):\(line): \(message)")
        }
    }

    static func expectEqual<T: Equatable>(
        _ actual: @autoclosure () -> T,
        _ expected: @autoclosure () -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualValue = actual()
        let expectedValue = expected()
        expect(
            actualValue == expectedValue,
            "Expected \(String(describing: expectedValue)), got \(String(describing: actualValue))",
            file: file,
            line: line
        )
    }

    /// A fresh directory under the temporary directory; callers remove it with `defer`.
    static func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFlowIOSTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs the main run loop until `condition` holds or `timeout` passes.
    static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

/// Invented records shared by the suites. Times are fixed so no test depends on the wall clock.
enum Fixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let requestID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let otherRequestID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let instanceID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
    static let otherInstanceID = UUID(uuidString: "00000000-0000-4000-8000-0000000000A2")!
    static let hostRunID = UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!
    static let otherHostRunID = UUID(uuidString: "00000000-0000-4000-8000-0000000000C2")!
    static let documentA = UUID(uuidString: "00000000-0000-4000-8000-0000000000D1")!
    static let documentB = UUID(uuidString: "00000000-0000-4000-8000-0000000000D2")!

    static func intent(_ action: KeyboardIntent.Action, _ requestID: UUID = requestID,
                       instance: UUID = instanceID, at issuedAt: Date = now) -> KeyboardIntent {
        KeyboardIntent(requestID: requestID, action: action, keyboardInstanceID: instance, issuedAt: issuedAt)
    }

    static func presence(seenAt: Date = now, instance: UUID = instanceID) -> KeyboardPresence {
        KeyboardPresence(keyboardInstanceID: instance, seenAt: seenAt)
    }

    static func dictation(_ phase: DictationStatus.Phase, _ requestID: UUID = requestID, hostRunID: UUID = hostRunID,
                          error: HostErrorCode? = nil, startedAt: Date = now.addingTimeInterval(-2),
                          updatedAt: Date = now) -> DictationStatus {
        DictationStatus(requestID: requestID, hostRunID: hostRunID, phase: phase, error: error,
                        startedAt: startedAt, updatedAt: updatedAt)
    }

    static func status(_ session: HostStatus.Session = .active, captureReady: Bool = true, heartbeatAt: Date = now,
                       dictation: DictationStatus? = nil, level: Float = 0, error: HostErrorCode? = nil) -> HostStatus {
        HostStatus(hostRunID: hostRunID, sessionID: UUID(uuidString: "00000000-0000-4000-8000-0000000000B1")!,
                   session: session, captureReady: captureReady, heartbeatAt: heartbeatAt,
                   sessionExpiresAt: heartbeatAt.addingTimeInterval(300), model: .ready, dictation: dictation,
                   level: level, error: error)
    }

    static func result(_ requestID: UUID = requestID, text: String = "Synthetic sample sentence",
                       pressEnter: Bool = false, createdAt: Date = now, hostRunID: UUID = hostRunID) -> DictationResult {
        DictationResult(requestID: requestID, hostRunID: hostRunID, text: text, pressEnter: pressEnter,
                        createdAt: createdAt)
    }
}
