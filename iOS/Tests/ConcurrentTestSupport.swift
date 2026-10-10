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
