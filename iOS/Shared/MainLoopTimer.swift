import Foundation

extension Timer {
    /// A timer added to the main run loop in its common modes, so it also fires while a touch or a scroll is
    /// tracked, that runs `body` on the main thread with itself. The run loop keeps the timer, and the timer
    /// keeps `body`: capture owners weakly, and invalidate a repeating timer whose owner is gone.
    @discardableResult
    static func mainLoop(after interval: TimeInterval, repeats: Bool = false, tolerance: TimeInterval = 0,
                         _ body: @escaping @MainActor @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { timer in
            MainActor.assumeIsolated { body(timer) }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
