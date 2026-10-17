import Foundation

/// Helpers for tests that must overlap work across threads rather than run it in sequence.
enum Concurrently {
    /// Runs `body(index)` on `count` threads that are all started before any is released, and fails
    /// instead of hanging when they do not all finish within `timeout`.
    static func run(_ count: Int, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                    _ body: @escaping @Sendable (Int) -> Void) {
        let ready = DispatchSemaphore(value: 0)
        let start = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        for index in 0..<count {
            done.enter()
            Thread {
                ready.signal()
                start.wait()
                body(index)
                done.leave()
            }.start()
        }
        for _ in 0..<count { ready.wait() }
        for _ in 0..<count { start.signal() }
        TestSupport.expect(done.wait(timeout: .now() + timeout) == .success,
                           "threads did not finish within \(timeout) s", file: file, line: line)
    }

    /// Runs `body` on another thread and fails instead of hanging if it deadlocks.
    static func withTimeout(_ timeout: TimeInterval, _ message: String, file: StaticString = #filePath,
                            line: UInt = #line, _ body: @escaping @Sendable () -> Void) {
        run(1, timeout: timeout, file: file, line: line) { _ in body() }
    }
}

/// A value shared between test threads.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func update<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// A `SpeechStream` that records what it is fed and finishes when told to. The sample buffer feeds it
/// from the capture thread. Like the app's stream, cancelling it ends a waiting `finish`, and `onEnd`
/// runs once it is finished or cancelled and its model work (`holdsWork`, a running chunk) has drained.
final class FakeSpeechStream: SpeechStream, @unchecked Sendable {
    private struct State {
        var samples: [Float] = []
        var cancelled = false
        var finishes = 0
        var result: Result<String, Error>?
        var waiting: CheckedContinuation<String, Error>?
        var done = false
        var holdsWork = false
        var ended = false
    }

    private let state = Locked(State())
    private let onEnd: (@Sendable () -> Void)?

    init(onEnd: (@Sendable () -> Void)? = nil) {
        self.onEnd = onEnd
    }

    var samples: [Float] { state.current.samples }
    var isCancelled: Bool { state.current.cancelled }
    var finishCount: Int { state.current.finishes }

    /// A chunk is running: the end waits for `finishWork()`.
    var holdsWork: Bool {
        get { state.current.holdsWork }
        set { state.update { $0.holdsWork = newValue } }
    }

    func append(_ samples: [Float]) {
        state.update { $0.samples += samples }
    }

    func finish() async throws -> String {
        defer { markDone() }
        return try await withCheckedThrowingContinuation { continuation in
            let ready: Result<String, Error>? = state.update { state in
                state.finishes += 1
                if state.cancelled { return .failure(CancellationError()) }
                if let result = state.result { return result }
                state.waiting = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    /// Completes a waiting `finish`, or the next one.
    func complete(_ result: Result<String, Error>) {
        let waiting = state.update { state -> CheckedContinuation<String, Error>? in
            state.result = result
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(with: result)
    }

    func cancel() {
        let waiting = state.update { state -> CheckedContinuation<String, Error>? in
            state.cancelled = true
            defer { state.waiting = nil }
            return state.waiting
        }
        waiting?.resume(throwing: CancellationError())
        markDone()
    }

    /// The running chunk returns.
    func finishWork() {
        holdsWork = false
        endIfDrained()
    }

    private func markDone() {
        state.update { $0.done = true }
        endIfDrained()
    }

    private func endIfDrained() {
        let end = state.update { state -> Bool in
            guard state.done, !state.holdsWork, !state.ended else { return false }
            state.ended = true
            return true
        }
        if end { onEnd?() }
    }
}
