import Foundation

/// `Timer.mainLoop`: the main-run-loop timers of the app and the keyboard (key repeat, the trackpad hold,
/// undo, polling) fire on the main thread in every common mode, once or until invalidated, and keep only
/// what their body captures.
enum MainLoopTimerTests {
    static var tests: [TestCase] {
        [
            ("firesOnceOnTheMainThreadWithItself", isolated(testFiresOnceOnTheMainThreadWithItself)),
            ("repeatsUntilInvalidated", isolated(testRepeatsUntilInvalidated)),
            ("firesInEveryCommonMode", isolated(testFiresInEveryCommonMode)),
            ("keepsItsOwnerOnlyWeakly", isolated(testKeepsItsOwnerOnlyWeakly)),
            ("takesTheTolerance", isolated(testTakesTheTolerance)),
        ]
    }

    private static func isolated(_ body: @escaping @MainActor () -> Void) -> () -> Void {
        { MainActor.assumeIsolated { body() } }
    }

    /// What the timers saw, on the main actor.
    @MainActor
    private final class Fired {
        var timers: [Timer] = []
        var onMain: [Bool] = []
        var ended = false
    }

    @MainActor
    private static func testFiresOnceOnTheMainThreadWithItself() {
        let fired = Fired()
        let timer = Timer.mainLoop(after: 0.01) { timer in
            fired.timers.append(timer)
            fired.onMain.append(Thread.isMainThread)
        }
        TestSupport.expect(fired.timers.isEmpty, "fired before its interval")
        TestSupport.expect(TestSupport.waitUntil(timeout: 5) { !fired.timers.isEmpty }, "never fired")
        TestSupport.expect(!TestSupport.waitUntil(timeout: 0.1) { fired.timers.count > 1 }, "fired again")
        TestSupport.expect(fired.timers.first === timer, "body got another timer")
        TestSupport.expectEqual(fired.onMain, [true])
        TestSupport.expect(!timer.isValid, "a one-shot timer is still valid")
    }

    @MainActor
    private static func testRepeatsUntilInvalidated() {
        let fired = Fired()
        let timer = Timer.mainLoop(after: 0.01, repeats: true) { timer in
            fired.timers.append(timer)
            if fired.timers.count == 3 { timer.invalidate() }
        }
        TestSupport.expect(TestSupport.waitUntil(timeout: 5) { fired.timers.count == 3 }, "did not repeat")
        TestSupport.expect(!TestSupport.waitUntil(timeout: 0.1) { fired.timers.count > 3 }, "fired after invalidation")
        TestSupport.expect(fired.timers.allSatisfy { $0 === timer }, "body got another timer")
        TestSupport.expect(!timer.isValid, "still valid")
    }

    @MainActor
    private static func testFiresInEveryCommonMode() {
        // A mode of the main run loop's common modes, as UIKit's tracking mode is while a touch is tracked.
        let tracking = RunLoop.Mode("LocalFlowTestsTracking")
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: tracking.rawValue as CFString))
        let fired = Fired()
        let defaultOnly = Locked(false)
        let control = Timer(timeInterval: 0.01, repeats: false) { _ in defaultOnly.update { $0 = true } }
        RunLoop.main.add(control, forMode: .default)
        defer { control.invalidate() }
        Timer.mainLoop(after: 0.05) { fired.timers.append($0) }
        let deadline = Date().addingTimeInterval(5)
        while fired.timers.isEmpty, Date() < deadline {
            _ = RunLoop.main.run(mode: tracking, before: Date().addingTimeInterval(0.01))
        }
        TestSupport.expectEqual(fired.timers.count, 1)
        // A timer in the default mode alone waits while the run loop runs in the other mode.
        TestSupport.expect(!defaultOnly.current, "the default-mode timer fired in the tracking mode")
    }

    /// An owner holding its repeating timer, which captures it weakly as the app's and keyboard's owners do.
    @MainActor
    private final class Owner {
        var timer: Timer?
        var ticks = 0

        func start(_ fired: Fired) {
            timer = Timer.mainLoop(after: 0.01, repeats: true) { [weak self] timer in
                guard let self else {
                    fired.ended = true
                    return timer.invalidate()
                }
                self.ticks += 1
            }
        }
    }

    @MainActor
    private static func testKeepsItsOwnerOnlyWeakly() {
        let fired = Fired()
        var owner: Owner? = Owner()
        owner?.start(fired)
        let timer = owner?.timer
        TestSupport.expect(TestSupport.waitUntil(timeout: 5) { (owner?.ticks ?? 0) >= 1 }, "never ticked")
        weak let released = owner
        owner = nil
        TestSupport.expect(released == nil, "the timer kept its owner")
        TestSupport.expect(TestSupport.waitUntil(timeout: 5) { fired.ended }, "never saw its owner gone")
        TestSupport.expect(timer?.isValid == false, "still valid without its owner")
    }

    @MainActor
    private static func testTakesTheTolerance() {
        let timer = Timer.mainLoop(after: 60, tolerance: 0.05) { _ in }
        defer { timer.invalidate() }
        TestSupport.expectEqual(timer.tolerance, 0.05)
        TestSupport.expect(abs(timer.fireDate.timeIntervalSinceNow - 60) < 5, "fire date \(timer.fireDate)")
        let exact = Timer.mainLoop(after: 60) { _ in }
        defer { exact.invalidate() }
        TestSupport.expectEqual(exact.tolerance, 0)
    }
}
