import Foundation

enum CursorMotionTests {
    static var tests: [TestCase] {
        [
            ("measuredActivationAndSlop", testMeasuredActivationAndSlop),
            ("measuredGainValues", testMeasuredGainValues),
            ("gainIsContinuousAndRising", testGainIsContinuousAndRising),
            ("gainIsPerEventAndSymmetric", testGainIsPerEventAndSymmetric),
            ("eventStepScaleCorrectsTheStep", testEventStepScaleCorrectsTheStep),
            ("multipliersScaleMovementAndGain", testMultipliersScaleMovementAndGain),
            ("noDeadZoneOrRounding", testNoDeadZoneOrRounding),
            ("clampForgetsOvershoot", testClampForgetsOvershoot),
            ("measuredClamps", testMeasuredClamps),
        ]
    }

    private static let measured = TrackpadParameters.standard

    private static func close(_ actual: Double, _ expected: Double, _ tolerance: Double, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        TestSupport.expect(abs(actual - expected) <= tolerance, "\(what): expected \(expected), got \(actual)",
                           file: file, line: line)
    }

    private static func testMeasuredActivationAndSlop() {
        // Device (iPhone 15 Pro): 0.403 ± 0.004 s with a thumb, 0.399 s with XCUITest (0.381 s in the
        // simulator). Up to 16 pt (straight line from touch-down) activates and 18 pt does not.
        TestSupport.expectEqual(measured.holdDuration, 0.40)
        TestSupport.expectEqual(measured.holdSlop, 16)
        // Apple has no drag-to-activate.
        TestSupport.expectEqual(measured.dragActivationDistance, .infinity)
    }

    private static func testMeasuredGainValues() {
        // ARCHITECTURE.md, "Measured Apple keyboard behavior": g(1) ≈ 1.04, g(3) ≈ 1.32, g(7) ≈ 1.905,
        // g(15) ≈ 2.567, g(30) ≈ 3.36.
        close(measured.gain(forStep: 0), 1, 1e-12, "g(0)")
        close(measured.gain(forStep: 1), 1.04, 1e-9, "g(1)")
        close(measured.gain(forStep: 2), 1.16, 1e-9, "g(2)")
        close(measured.gain(forStep: 3), 1.32, 1e-9, "g(3)")
        close(measured.gain(forStep: 7), 1.905, 0.005, "g(7)")
        close(measured.gain(forStep: 15), 2.567, 0.005, "g(15)")
        close(measured.gain(forStep: 30), 3.36, 0.005, "g(30)")
        close(measured.gain(forStep: -5), 1, 1e-12, "a negative step reads as none")
    }

    private static func testGainIsContinuousAndRising() {
        let epsilon = 1e-9
        for knee in [measured.quadraticLimit, measured.linearLimit] {
            let below = measured.gain(forStep: knee - epsilon)
            let above = measured.gain(forStep: knee + epsilon)
            close(above, below, 0.001, "continuity at \(knee)")
        }
        close(measured.gain(forStep: 5.92), 1.787, 0.001, "g(5.92)")
        var previous = 0.0
        for step in stride(from: 0.0, through: 60, by: 0.05) {
            let gain = measured.gain(forStep: step)
            TestSupport.expect(gain >= previous - 1e-12, "gain dropped at \(step)")
            previous = gain
        }
    }

    private static func testGainIsPerEventAndSymmetric() {
        // The same 12 pt of finger travel as one event or as twelve: the gain follows the event's
        // step, never the time between events.
        var oneEvent = FloatingCursor(parameters: measured, x: 0, y: 0)
        oneEvent.move(dx: 12, dy: 0)
        var manyEvents = FloatingCursor(parameters: measured, x: 0, y: 0)
        for _ in 0 ..< 12 { manyEvents.move(dx: 1, dy: 0) }
        close(oneEvent.x, 12 * measured.gain(forStep: 12), 1e-9, "one 12-pt event")
        close(manyEvents.x, 12 * 1.04, 1e-9, "twelve 1-pt events")
        // On a diagonal, one gain from the 2D step moves both axes, the same in every direction.
        var diagonal = FloatingCursor(parameters: measured, x: 0, y: 0)
        let moved = diagonal.move(dx: -3, dy: 4)
        close(moved.dx, -3 * measured.gain(forStep: 5), 1e-9, "diagonal x")
        close(moved.dy, 4 * measured.gain(forStep: 5), 1e-9, "diagonal y")
        TestSupport.expect(abs(moved.dy / moved.dx + 4.0 / 3) < 1e-12, "the direction changed")
        var back = FloatingCursor(parameters: measured, x: 0, y: 0)
        back.move(dx: 3, dy: -4)
        close(back.x, -diagonal.x, 1e-12, "symmetric x")
        close(back.y, -diagonal.y, 1e-12, "symmetric y")
        // A vertical-only step uses the same curve as a horizontal one.
        var vertical = FloatingCursor(parameters: measured, x: 0, y: 0)
        vertical.move(dx: 0, dy: 7)
        close(vertical.y, 7 * measured.gain(forStep: 7), 1e-9, "vertical")
        // Broken input is dropped.
        var broken = FloatingCursor(parameters: measured, x: 5, y: 5)
        broken.move(dx: .nan, dy: 1)
        broken.move(dx: 1, dy: .infinity)
        TestSupport.expectEqual(broken.x, 5)
        TestSupport.expectEqual(broken.y, 5)
    }

    private static func testEventStepScaleCorrectsTheStep() {
        TestSupport.expectEqual(measured.eventStepScale, 1)
        var halved = measured
        halved.eventStepScale = 2
        // 120 Hz delivery carries half-size steps; scale 2 reads them as the 60 Hz steps the curve was
        // measured with.
        close(halved.gain(forStep: 3.5), measured.gain(forStep: 7), 1e-12, "scaled step")
    }

    private static func testMultipliersScaleMovementAndGain() {
        let slower = measured.tuned(sensitivity: 0.5, acceleration: 1)
        close(slower.travelFactor(forStep: 7), 0.5 * measured.gain(forStep: 7), 1e-12, "sensitivity scales movement")
        close(slower.gain(forStep: 7), measured.gain(forStep: 7), 1e-12, "sensitivity leaves the gain")
        let flatter = measured.tuned(sensitivity: 1, acceleration: 0.5)
        close(flatter.gain(forStep: 15), 1 + (measured.gain(forStep: 15) - 1) * 0.5, 1e-12, "acceleration scales g - 1")
        close(flatter.gain(forStep: 0), 1, 1e-12, "acceleration leaves slow movement exact")
        // Out-of-range or broken multipliers are clamped or ignored.
        TestSupport.expectEqual(measured.tuned(sensitivity: 100, acceleration: 1).sensitivity, 4)
        TestSupport.expectEqual(measured.tuned(sensitivity: 0.01, acceleration: 1).sensitivity, 0.25)
        TestSupport.expectEqual(measured.tuned(sensitivity: .nan, acceleration: .infinity), measured)
        TestSupport.expectEqual(measured.tuned(sensitivity: 1, acceleration: 1), measured)
    }

    private static func testNoDeadZoneOrRounding() {
        // 1 pt of slow finger movement moves the point 1 pt (measured: no dead zone), and many tiny
        // events add up exactly.
        var point = FloatingCursor(parameters: .flat, x: 0, y: 0)
        for _ in 0 ..< 200 { point.move(dx: 0.5, dy: -0.25) }
        close(point.x, 100, 1e-9, "x")
        close(point.y, -50, 1e-9, "y")
        var measuredPoint = FloatingCursor(parameters: measured, x: 0, y: 0)
        measuredPoint.move(dx: 0.1, dy: 0)
        close(measuredPoint.x, 0.1 * 1.0004, 1e-12, "a tenth of a point")
    }

    private static func testClampForgetsOvershoot() {
        var point = FloatingCursor(parameters: .flat, x: 50, y: 10)
        point.move(dx: 500, dy: -300)
        point.clamp(x: 1.5 ... 98.5, y: 3 ... 18)
        TestSupport.expectEqual(point.x, 98.5)
        TestSupport.expectEqual(point.y, 3)
        // The reversal answers at once: nothing of the 450-point overshoot is remembered.
        point.move(dx: -1, dy: 1)
        TestSupport.expectEqual(point.x, 97.5)
        TestSupport.expectEqual(point.y, 4)
        point.place(x: 20, y: 30)
        TestSupport.expectEqual(point.x, 20)
        TestSupport.expectEqual(point.y, 30)
    }

    private static func testMeasuredClamps() {
        // Device: the left clamp is x = 1.0 (1.5 in the simulator); the right one is unmeasured on device.
        TestSupport.expectEqual(measured.leftInset, 1.0)
        TestSupport.expectEqual(measured.rightInset, 1.5)
        TestSupport.expectEqual(measured.topOvershoot, 7)
        TestSupport.expectEqual(measured.bottomOvershoot, 8)
    }
}
