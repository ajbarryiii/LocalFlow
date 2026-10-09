import Foundation

enum CursorMotionTests {
    static var tests: [TestCase] {
        [
            ("gainIsOneWhenSlowAndCappedWhenFast", testGainIsOneWhenSlowAndCappedWhenFast),
            ("gainRisesSmoothlyAndMonotonically", testGainRisesSmoothlyAndMonotonically),
            ("multipliersScaleGainAndAcceleration", testMultipliersScaleGainAndAcceleration),
            ("speedComesFromTouchTimestamps", testSpeedComesFromTouchTimestamps),
            ("residualsCarryBetweenSamples", testResidualsCarryBetweenSamples),
            ("wideCharactersTakeMoreTravel", testWideCharactersTakeMoreTravel),
            ("hysteresisStopsFlicker", testHysteresisStopsFlicker),
            ("edgesBlockOnlyPastATypicalCharacter", testEdgesBlockOnlyPastATypicalCharacter),
            ("lineStepsHalfwayWithHysteresis", testLineStepsHalfwayWithHysteresis),
            ("stopAndLimit", testStopAndLimit),
        ]
    }

    private static let parameters = TrackpadParameters.standard

    private static func testGainIsOneWhenSlowAndCappedWhenFast() {
        TestSupport.expectEqual(parameters.gain(forSpeed: 0), 1)
        TestSupport.expectEqual(parameters.gain(forSpeed: parameters.lowSpeed), 1)
        TestSupport.expectEqual(parameters.gain(forSpeed: parameters.highSpeed), parameters.maximumGain)
        TestSupport.expectEqual(parameters.gain(forSpeed: 10 * parameters.highSpeed), parameters.maximumGain)
        TestSupport.expectEqual(parameters.gain(forSpeed: -50), 1)
    }

    private static func testGainRisesSmoothlyAndMonotonically() {
        var previous = 0.0
        for speed in stride(from: 0.0, through: 2_000, by: 10) {
            let gain = parameters.gain(forSpeed: speed)
            TestSupport.expect(gain >= previous, "gain dropped at \(speed)")
            // Smoothstep: no jump between neighbouring speeds.
            TestSupport.expect(previous == 0 || gain - previous < 0.05, "gain jumped at \(speed)")
            previous = gain
        }
        let middle = parameters.gain(forSpeed: (parameters.lowSpeed + parameters.highSpeed) / 2)
        TestSupport.expect(abs(middle - (1 + parameters.maximumGain) / 2) < 1e-9, "midpoint gain \(middle)")
    }

    private static func testMultipliersScaleGainAndAcceleration() {
        let slower = parameters.tuned(sensitivity: 0.5, acceleration: 1)
        TestSupport.expectEqual(slower.gain(forSpeed: 0), 0.5)
        TestSupport.expectEqual(slower.gain(forSpeed: 5_000), 0.5 * parameters.maximumGain)
        let flat = parameters.tuned(sensitivity: 1, acceleration: 0.25)
        TestSupport.expectEqual(flat.gain(forSpeed: 5_000), 1 + (parameters.maximumGain - 1) * 0.25)
        let steep = parameters.tuned(sensitivity: 2, acceleration: 2)
        TestSupport.expectEqual(steep.gain(forSpeed: 0), 2)
        TestSupport.expectEqual(steep.gain(forSpeed: 5_000), 2 * (1 + (parameters.maximumGain - 1) * 2))
        // Out-of-range or broken multipliers are clamped or ignored.
        TestSupport.expectEqual(parameters.tuned(sensitivity: 100, acceleration: 1).baseGain, 4)
        TestSupport.expectEqual(parameters.tuned(sensitivity: .nan, acceleration: .infinity), parameters)
        TestSupport.expectEqual(parameters.tuned(sensitivity: 1, acceleration: 1), parameters)
    }

    private static func testSpeedComesFromTouchTimestamps() {
        // The same 4-point samples, 1/120 s apart (480 pt/s) and 1/30 s apart (120 pt/s).
        var fast = CursorMotion(parameters: parameters)
        var slow = CursorMotion(parameters: parameters)
        for i in 0 ..< 30 {
            fast.add(dx: 4, dy: 0, timestamp: 10 + Double(i) / 120)
            slow.add(dx: 4, dy: 0, timestamp: 10 + Double(i) / 30)
        }
        TestSupport.expect(abs(fast.speed - 480) < 5, "fast speed \(fast.speed)")
        TestSupport.expect(abs(slow.speed - 120) < 2, "slow speed \(slow.speed)")
        TestSupport.expect(fast.horizontal > slow.horizontal * 1.3, "acceleration ignored")
        TestSupport.expect(abs(slow.horizontal - 120) < 1, "slow travel \(slow.horizontal)")
        // A sample with the same timestamp, or one from the past, adds travel but no speed spike.
        var motion = CursorMotion(parameters: parameters)
        motion.add(dx: 1, dy: 0, timestamp: 5)
        motion.add(dx: 1, dy: 0, timestamp: 5)
        motion.add(dx: 1, dy: 0, timestamp: 4)
        TestSupport.expectEqual(motion.speed, 0)
        TestSupport.expectEqual(motion.horizontal, 3)
        // Broken input is dropped.
        motion.add(dx: .nan, dy: 1, timestamp: 6)
        TestSupport.expectEqual(motion.horizontal, 3)
    }

    private static func testResidualsCarryBetweenSamples() {
        // Many tiny slow samples add up to whole characters, with nothing lost to rounding.
        var motion = CursorMotion(parameters: parameters)
        var steps = 0
        for i in 0 ..< 200 {
            motion.add(dx: 0.5, dy: 0, timestamp: Double(i) / 120)
            steps += motion.takeHorizontalSteps { _ in 10 }.steps
        }
        // 100 points over 10-point characters, crossing at 60 % of each: at 6, 16, ... 96.
        TestSupport.expectEqual(steps, 10)
        TestSupport.expect(abs(Double(steps) * 10 + motion.horizontal - 100) < 1e-9, "travel lost")
    }

    private static func testWideCharactersTakeMoreTravel() {
        func steps(over width: Double) -> Int {
            var motion = CursorMotion(parameters: parameters)
            motion.add(dx: 60, dy: 0, timestamp: 0)
            return motion.takeHorizontalSteps { _ in width }.steps
        }
        TestSupport.expectEqual(steps(over: 5), 12)
        TestSupport.expectEqual(steps(over: 10), 6)
        TestSupport.expectEqual(steps(over: 16), 4)
        var motion = CursorMotion(parameters: parameters)
        motion.add(dx: -26, dy: 0, timestamp: 0)
        // Backwards crosses the characters before the caret: 16, 5, 5 → three steps.
        let widths: [Int: Double] = [-1: 16, -2: 5, -3: 5, -4: 16]
        TestSupport.expectEqual(motion.takeHorizontalSteps { widths[$0] }.steps, -3)
    }

    private static func testHysteresisStopsFlicker() {
        var motion = CursorMotion(parameters: parameters)
        motion.add(dx: 6, dy: 0, timestamp: 0)
        TestSupport.expectEqual(motion.takeHorizontalSteps { _ in 10 }.steps, 1)
        // The pointer now rests 4 points behind the new caret; wobbling 1 point either way does nothing.
        for (i, dx) in [-1.0, 1, -1, 1, -1.5].enumerated() {
            motion.add(dx: dx, dy: 0, timestamp: Double(i + 1))
            TestSupport.expectEqual(motion.takeHorizontalSteps { _ in 10 }.steps, 0)
        }
        motion.add(dx: -1, dy: 0, timestamp: 10)
        TestSupport.expectEqual(motion.takeHorizontalSteps { _ in 10 }.steps, -1)
    }

    private static func testEdgesBlockOnlyPastATypicalCharacter() {
        var motion = CursorMotion(parameters: parameters)
        motion.add(dx: 3, dy: 0, timestamp: 0)
        let small = motion.takeHorizontalSteps { _ in nil }
        TestSupport.expectEqual(small, CursorMotion.HorizontalSteps(steps: 0, blockedForward: false, blockedBackward: false))
        motion.add(dx: 4, dy: 0, timestamp: 1)
        TestSupport.expect(motion.takeHorizontalSteps { _ in nil }.blockedForward, "not blocked forward")
        var backward = CursorMotion(parameters: parameters)
        backward.add(dx: -25, dy: 0, timestamp: 0)
        let result = backward.takeHorizontalSteps { $0 == -1 ? 10 : nil }
        TestSupport.expectEqual(result.steps, -1)
        TestSupport.expect(result.blockedBackward, "not blocked backward")
    }

    private static func testLineStepsHalfwayWithHysteresis() {
        var motion = CursorMotion(parameters: parameters)
        motion.add(dx: 0, dy: 12, timestamp: 0)
        TestSupport.expectEqual(motion.takeLineSteps(lineHeight: 20), 0)
        motion.add(dx: 0, dy: 1.5, timestamp: 1)
        TestSupport.expectEqual(motion.takeLineSteps(lineHeight: 20), 1)
        // Resting near the boundary does not bounce back.
        motion.add(dx: 0, dy: -5, timestamp: 2)
        TestSupport.expectEqual(motion.takeLineSteps(lineHeight: 20), 0)
        motion.add(dx: 0, dy: -60, timestamp: 2)
        TestSupport.expectEqual(motion.takeLineSteps(lineHeight: 20), -3)
        TestSupport.expectEqual(motion.takeLineSteps(lineHeight: 0), 0)
        motion.stopVertical()
        motion.restoreLines(2, lineHeight: 20)
        TestSupport.expectEqual(motion.takeLineSteps(lineHeight: 20), 2)
    }

    private static func testStopAndLimit() {
        var motion = CursorMotion(parameters: parameters)
        motion.add(dx: 30, dy: 30, timestamp: 0)
        motion.stopHorizontal(atEnd: true)
        TestSupport.expectEqual(motion.horizontal, 0)
        motion.add(dx: -5, dy: 0, timestamp: 1)
        motion.stopHorizontal(atEnd: true)
        TestSupport.expectEqual(motion.horizontal, -5)
        motion.stopHorizontal(atEnd: false)
        TestSupport.expectEqual(motion.horizontal, 0)
        motion.stopVertical()
        TestSupport.expectEqual(motion.vertical, 0)
        motion.add(dx: 1_000, dy: 0, timestamp: 2)
        motion.limitHorizontal(to: 600)
        TestSupport.expectEqual(motion.horizontal, 600)
        motion.consumeHorizontal(9)
        TestSupport.expectEqual(motion.horizontal, 591)
    }
}
