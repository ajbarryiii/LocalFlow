import Foundation

/// `ModelLoadSlot`: the keyboard loads each typing model at most once per wanted source, however often it
/// reappears, and drops results no longer wanted without ever leaving a wanted model unloaded for good.
enum ModelLoadSlotTests {
    static var tests: [TestCase] {
        [
            ("firstRequestStartsOneLoad", testFirstRequestStartsOneLoad),
            ("reappearingWhileLoadingStartsNothing", testReappearingWhileLoadingStartsNothing),
            ("reappearingWithModelHeldStartsNothing", testReappearingWithModelHeldStartsNothing),
            ("turningOffDropsModelOnce", testTurningOffDropsModelOnce),
            ("noSourceStartsNothing", testNoSourceStartsNothing),
            ("offWhileLoadingDropsResultAndOnLoadsAgain", testOffWhileLoadingDropsResultAndOnLoadsAgain),
            ("offThenOnWhileLoadingKeepsTheLoad", testOffThenOnWhileLoadingKeepsTheLoad),
            ("newSourceDropsModelAndLoads", testNewSourceDropsModelAndLoads),
            ("newSourceSupersedesLoadInFlight", testNewSourceSupersedesLoadInFlight),
            ("backToSupersededSourceLoadsAgain", testBackToSupersededSourceLoadsAgain),
            ("failedLoadLoadsAgainOnNextRequest", testFailedLoadLoadsAgainOnNextRequest),
            ("ticketEndsOnlyOnce", testTicketEndsOnlyOnce),
        ]
    }

    private typealias Slot = ModelLoadSlot<String>

    private static let bundle = "bundle-a"
    private static let otherBundle = "bundle-b"

    /// The ticket a step must start.
    private static func started(_ step: Slot.Step, file: StaticString = #filePath, line: UInt = #line) -> Slot.Ticket {
        guard let ticket = step.load else {
            TestSupport.expect(false, "Expected a load to start", file: file, line: line)
            fatalError()
        }
        return ticket
    }

    private static func testFirstRequestStartsOneLoad() {
        var slot = Slot()
        let step = slot.request(bundle)
        TestSupport.expect(!step.dropModel, "Nothing is held yet")
        TestSupport.expectEqual(started(step).source, bundle)
        TestSupport.expectEqual(slot.held, nil)
    }

    private static func testReappearingWhileLoadingStartsNothing() {
        var slot = Slot()
        let ticket = started(slot.request(bundle))
        // Switching to the emoji keyboard and back, again and again, while the model is still loading.
        for _ in 0 ..< 5 {
            TestSupport.expectEqual(slot.request(bundle), Slot.Step(dropModel: false, load: nil))
        }
        TestSupport.expect(slot.finish(ticket, loaded: true), "The one load is installed")
        TestSupport.expectEqual(slot.held, bundle)
    }

    private static func testReappearingWithModelHeldStartsNothing() {
        var slot = Slot()
        let ticket = started(slot.request(bundle))
        _ = slot.finish(ticket, loaded: true)
        TestSupport.expectEqual(slot.request(bundle), Slot.Step(dropModel: false, load: nil))
        TestSupport.expectEqual(slot.held, bundle)
    }

    private static func testTurningOffDropsModelOnce() {
        var slot = Slot()
        _ = slot.finish(started(slot.request(bundle)), loaded: true)
        TestSupport.expectEqual(slot.request(nil), Slot.Step(dropModel: true, load: nil))
        TestSupport.expectEqual(slot.held, nil)
        TestSupport.expectEqual(slot.request(nil), Slot.Step(dropModel: false, load: nil))
    }

    private static func testNoSourceStartsNothing() {
        var slot = Slot()
        TestSupport.expectEqual(slot.request(nil), Slot.Step(dropModel: false, load: nil))
        TestSupport.expectEqual(slot.loading, nil)
    }

    private static func testOffWhileLoadingDropsResultAndOnLoadsAgain() {
        var slot = Slot()
        let first = started(slot.request(bundle))
        _ = slot.request(nil)
        TestSupport.expect(!slot.finish(first, loaded: true), "A load ending while the setting is off is discarded")
        TestSupport.expectEqual(slot.held, nil)
        // Turned back on after that load ended: it loads again.
        let second = started(slot.request(bundle))
        TestSupport.expect(second != first, "A new load has its own ticket")
        TestSupport.expect(slot.finish(second, loaded: true), "The new load is installed")
        TestSupport.expectEqual(slot.held, bundle)
    }

    private static func testOffThenOnWhileLoadingKeepsTheLoad() {
        var slot = Slot()
        let ticket = started(slot.request(bundle))
        TestSupport.expectEqual(slot.request(nil), Slot.Step(dropModel: false, load: nil))
        // Back on before the load ended: the same load serves, and no second one starts.
        TestSupport.expectEqual(slot.request(bundle), Slot.Step(dropModel: false, load: nil))
        TestSupport.expect(slot.finish(ticket, loaded: true), "The load still in flight is installed")
        TestSupport.expectEqual(slot.held, bundle)
    }

    private static func testNewSourceDropsModelAndLoads() {
        var slot = Slot()
        _ = slot.finish(started(slot.request(bundle)), loaded: true)
        let step = slot.request(otherBundle)
        TestSupport.expect(step.dropModel, "The model from the old source is dropped")
        let ticket = started(step)
        TestSupport.expectEqual(ticket.source, otherBundle)
        TestSupport.expectEqual(slot.held, nil)
        TestSupport.expect(slot.finish(ticket, loaded: true), "The new source's model is installed")
        TestSupport.expectEqual(slot.held, otherBundle)
    }

    private static func testNewSourceSupersedesLoadInFlight() {
        var slot = Slot()
        let old = started(slot.request(bundle))
        let new = started(slot.request(otherBundle))
        TestSupport.expectEqual(new.source, otherBundle)
        TestSupport.expect(!slot.finish(old, loaded: true), "A superseded load is discarded")
        TestSupport.expectEqual(slot.held, nil)
        TestSupport.expect(slot.finish(new, loaded: true), "The current load is installed")
        TestSupport.expectEqual(slot.held, otherBundle)
    }

    private static func testBackToSupersededSourceLoadsAgain() {
        var slot = Slot()
        let first = started(slot.request(bundle))
        let other = started(slot.request(otherBundle))
        let again = started(slot.request(bundle))
        TestSupport.expectEqual(again.source, bundle)
        TestSupport.expect(again != first, "The superseded load is not reused")
        TestSupport.expect(!slot.finish(first, loaded: true), "The superseded load is discarded")
        TestSupport.expect(!slot.finish(other, loaded: true), "The load for the source no longer wanted is discarded")
        TestSupport.expect(slot.finish(again, loaded: true), "The latest load is installed")
        TestSupport.expectEqual(slot.held, bundle)
    }

    private static func testFailedLoadLoadsAgainOnNextRequest() {
        var slot = Slot()
        let failed = started(slot.request(bundle))
        TestSupport.expect(!slot.finish(failed, loaded: false), "Nothing is installed from a failed load")
        TestSupport.expectEqual(slot.held, nil)
        TestSupport.expectEqual(slot.loading, nil)
        let retry = started(slot.request(bundle))
        TestSupport.expect(retry != failed, "The retry has its own ticket")
        TestSupport.expect(slot.finish(retry, loaded: true), "The retry is installed")
        TestSupport.expectEqual(slot.held, bundle)
    }

    private static func testTicketEndsOnlyOnce() {
        var slot = Slot()
        let ticket = started(slot.request(bundle))
        TestSupport.expect(slot.finish(ticket, loaded: true), "The load is installed")
        _ = slot.request(nil)
        _ = slot.request(bundle)
        TestSupport.expect(!slot.finish(ticket, loaded: true), "An ended load cannot be installed again")
    }
}
