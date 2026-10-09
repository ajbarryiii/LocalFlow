import Foundation

enum DeleteRepeatTests {
    static var tests: [TestCase] {
        [
            ("charactersThenWords", testCharactersThenWords),
            ("scheduleTimes", testScheduleTimes),
            ("parametersDropIn", testParametersDropIn),
        ]
    }

    private static func testCharactersThenWords() {
        let schedule = DeleteRepeat()
        TestSupport.expectEqual(schedule.unit(atElapsed: 0.5), .character)
        TestSupport.expectEqual(schedule.unit(atElapsed: 3.49), .character)
        TestSupport.expectEqual(schedule.unit(atElapsed: 3.5), .word)
        TestSupport.expectEqual(schedule.unit(atElapsed: 30), .word)
    }

    private static func testScheduleTimes() {
        let schedule = DeleteRepeat()
        var fires: [TimeInterval] = []
        var last: TimeInterval?
        while fires.count < 40 {
            let next = schedule.nextFire(afterRepeatAt: last)
            fires.append(next)
            last = next
        }
        TestSupport.expectEqual(fires[0], 0.5)
        TestSupport.expect(abs(fires[1] - 0.6) < 1e-9, "second repeat \(fires[1])")
        // Characters every 0.1 s until the switch, which fires exactly at 3.5 s, then words every 0.2 s.
        let characterFires = fires.filter { schedule.unit(atElapsed: $0) == .character }
        TestSupport.expectEqual(characterFires.count, 30)
        let firstWord = fires.first { schedule.unit(atElapsed: $0) == .word }!
        TestSupport.expect(abs(firstWord - 3.5) < 1e-9, "first word at \(firstWord)")
        let index = fires.firstIndex(of: firstWord)!
        TestSupport.expect(abs(fires[index + 1] - fires[index] - 0.2) < 1e-9, "word interval")
        for (earlier, later) in zip(fires, fires.dropFirst()) {
            TestSupport.expect(later > earlier, "schedule must advance")
        }
    }

    private static func testParametersDropIn() {
        let measured = DeleteRepeatParameters(initialDelay: 0.4, characterInterval: 0.08, wordModeAfter: 2, wordInterval: 0.3)
        let schedule = DeleteRepeat(parameters: measured)
        TestSupport.expectEqual(schedule.nextFire(afterRepeatAt: nil), 0.4)
        TestSupport.expectEqual(schedule.unit(atElapsed: 2), .word)
        TestSupport.expect(abs(schedule.nextFire(afterRepeatAt: 2) - 2.3) < 1e-9, "measured word interval")
        TestSupport.expectEqual(DeleteRepeatParameters.standard, DeleteRepeatParameters())
    }
}
