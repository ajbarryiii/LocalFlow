import Foundation

enum DeleteRepeatTests {
    static var tests: [TestCase] {
        [
            ("measuredParameters", testMeasuredParameters),
            ("charactersThenTwoWords", testCharactersThenTwoWords),
            ("scheduleTimes", testScheduleTimes),
            ("parametersDropIn", testParametersDropIn),
            ("heldKeyIsBoundToItsPressAndField", testHeldKeyIsBoundToItsPressAndField),
        ]
    }

    private static func close(_ actual: Double, _ expected: Double, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        TestSupport.expect(abs(actual - expected) < 1e-9, "\(what): expected \(expected), got \(actual)", file: file, line: line)
    }

    private static func testMeasuredParameters() {
        // ARCHITECTURE.md, "Measured Apple keyboard behavior"; the first deletion as measured on device
        // (0.087 s in the simulator).
        let measured = DeleteRepeatParameters.standard
        TestSupport.expectEqual(measured.firstDeletionDelay, 0.12)
        TestSupport.expectEqual(DeleteRepeat().firstDeletion, 0.12)
        TestSupport.expectEqual(measured.initialDelay, 0.50)
        TestSupport.expectEqual(measured.characterInterval, 0.10)
        TestSupport.expectEqual(measured.charactersBeforeWords, 21)
        TestSupport.expectEqual(measured.wordInterval, 0.354)
        TestSupport.expectEqual(measured.wordsPerTick, 2)
    }

    private static func testCharactersThenTwoWords() {
        let schedule = DeleteRepeat()
        // The first deletion and repeats 1–20 are the 21 characters; repeat 21 deletes two words.
        for index in 1 ... 20 { TestSupport.expectEqual(schedule.repeatAt(index).unit, .character) }
        TestSupport.expectEqual(schedule.repeatAt(21).unit, .words(2))
        TestSupport.expectEqual(schedule.repeatAt(40).unit, .words(2))
    }

    private static func testScheduleTimes() {
        let schedule = DeleteRepeat()
        // Times from touch-down: the first deletion at 0.12 s, the first repeat 0.50 s after it.
        close(schedule.repeatAt(1).time, 0.62, "first repeat")
        close(schedule.repeatAt(2).time, 0.72, "second repeat")
        // The 21st character about 2.52 s after touch-down, as measured on device.
        close(schedule.repeatAt(20).time, 2.52, "21st character")
        // Word mode 2.5 s after the first deletion, then every 0.354 s.
        close(schedule.repeatAt(21).time - schedule.firstDeletion, 2.5, "first word tick")
        close(schedule.repeatAt(22).time, 2.974, "second word tick")
        close(schedule.repeatAt(23).time, 3.328, "third word tick")
        var previous = 0.0
        for index in 1 ... 60 {
            let time = schedule.repeatAt(index).time
            TestSupport.expect(time > previous, "schedule must advance at \(index)")
            previous = time
        }
        // Out-of-range indexes read as the first repeat.
        TestSupport.expectEqual(schedule.repeatAt(0).time, schedule.repeatAt(1).time)
    }

    private static func testParametersDropIn() {
        let measured = DeleteRepeatParameters(initialDelay: 0.4, characterInterval: 0.08, charactersBeforeWords: 5,
                                              wordInterval: 0.3, wordsPerTick: 1)
        let schedule = DeleteRepeat(parameters: measured)
        close(schedule.repeatAt(1).time, 0.52, "first repeat")
        TestSupport.expectEqual(schedule.repeatAt(4).unit, .character)
        TestSupport.expectEqual(schedule.repeatAt(5).unit, .words(1))
        close(schedule.repeatAt(5).time, 0.84, "switch")
        close(schedule.repeatAt(6).time, 1.14, "word interval")
        TestSupport.expectEqual(DeleteRepeatParameters.standard, DeleteRepeatParameters())
    }
    private static func testHeldKeyIsBoundToItsPressAndField() {
        // The fourth review's P1: a held delete's timers outlived a focus change. Each deletion belongs to
        // its press and its field.
        let fieldA = UUID(), fieldB = UUID()
        let schedule = DeleteRepeat()
        var key = HeldDeleteKey(schedule: schedule)
        let first = key.began(at: 10, documentID: fieldA)
        close(first.firstAt, schedule.firstDeletion, "first deletion")
        // The schedule as before: one character, then the repeats.
        let fired = key.fire(token: first.token, documentID: fieldA)!
        TestSupport.expectEqual(fired.unit, .character)
        TestSupport.expectEqual(fired.field, fieldA)
        close(fired.nextAt, schedule.repeatAt(1).time, "first repeat")
        for index in 1 ... 25 {
            let next = key.fire(token: first.token, documentID: fieldA)!
            TestSupport.expectEqual(next.unit, schedule.repeatAt(index).unit)
            close(next.nextAt, schedule.repeatAt(index + 1).time, "repeat \(index)")
        }
        // A new press supersedes the old one's timers.
        let second = key.began(at: 20, documentID: fieldA)
        TestSupport.expect(key.fire(token: first.token, documentID: fieldA) == nil, "an old press fired")
        TestSupport.expect(key.press?.token == second.token, "the new press ended by an old timer")
        // A release before the first deletion deletes once, only in the field it began in.
        TestSupport.expectEqual(key.ended(cancelled: false, documentID: fieldA)?.deleteOnce, true)
        _ = key.began(at: 30, documentID: fieldA)
        TestSupport.expectEqual(key.ended(cancelled: false, documentID: fieldB)?.deleteOnce, false)
        _ = key.began(at: 50, documentID: fieldA)
        TestSupport.expectEqual(key.ended(cancelled: true, documentID: fieldA)?.deleteOnce, false)
        // Released while the field has no identity: it deletes once, bound to its field, and the keyboard
        // holds it until an identity appears (round 8).
        _ = key.began(at: 40, documentID: fieldA)
        let unidentified = key.ended(cancelled: false, documentID: nil)
        TestSupport.expectEqual(unidentified?.deleteOnce, true)
        TestSupport.expectEqual(unidentified?.field, fieldA)
        // Pressed while the field had no identity: bound to the first identity seen.
        let connecting = key.began(at: 45, documentID: nil)
        TestSupport.expectEqual(key.fire(token: connecting.token, documentID: nil)?.field, UUID?.none)
        TestSupport.expectEqual(key.fire(token: connecting.token, documentID: fieldB)?.field, fieldB)
        TestSupport.expect(key.fire(token: connecting.token, documentID: fieldA) == nil, "deleted in another field")
        // After a deletion, a release deletes nothing more; a second release is nothing.
        let held = key.began(at: 60, documentID: fieldA)
        _ = key.fire(token: held.token, documentID: fieldA)
        TestSupport.expectEqual(key.ended(cancelled: false, documentID: fieldA)?.deleteOnce, false)
        TestSupport.expect(key.ended(cancelled: false, documentID: fieldA) == nil, "released twice")
        // A timer in another field ends the press without deleting.
        let moved = key.began(at: 70, documentID: fieldA)
        TestSupport.expect(key.fire(token: moved.token, documentID: fieldB) == nil, "deleted in another field")
        TestSupport.expect(key.press == nil, "press kept in another field")
        // A focus change ends only a press bound to another identified field.
        _ = key.began(at: 80, documentID: fieldB)
        TestSupport.expectEqual(key.cancel(ifBoundElsewhereThan: fieldB), nil)
        TestSupport.expectEqual(key.cancel(ifBoundElsewhereThan: nil), nil)
        TestSupport.expect(key.cancel(ifBoundElsewhereThan: fieldA) != nil, "a press in another field kept")
        _ = key.began(at: 90, documentID: nil)
        TestSupport.expectEqual(key.cancel(ifBoundElsewhereThan: fieldA), nil)
    }
}
