import Foundation

/// The keyboard's editing side as `KeyboardInput` drives it (ARCHITECTURE.md, "Typing correctness is
/// paramount"): keys through `KeyboardEditor.press` with the real `TypingState`, the trackpad through
/// the real `TrackpadController` and `TrackpadSession` once per frame, and every host callback (the
/// trackpad's reports and our own edits' reports, delayed and coalesced) delivered between frames.
enum KeyboardEditorTests {
    static var tests: [TestCase] {
        [
            ("keysRunAtOnceWhileSettling", testKeysRunAtOnceWhileSettling),
            ("shiftNeverOvertakesWaitingLetters", testShiftNeverOvertakesWaitingLetters),
            ("ownTypingReportsNeverDropKeys", testOwnTypingReportsNeverDropKeys),
            ("ownTypingReportsNeverEndTheNextGesture", testOwnTypingReportsNeverEndTheNextGesture),
            ("keyReleasedAfterTheFieldChangedNeverLands", testKeyReleasedAfterTheFieldChangedNeverLands),
            ("waitingKeysStopAfterAReturn", testWaitingKeysStopAfterAReturn),
            ("abortWhileKeysWaitRepairsTheSplitFirst", testAbortWhileKeysWaitRepairsTheSplitFirst),
            ("keysWaitForTheWholeClusterRepair", testKeysWaitForTheWholeClusterRepair),
            ("cancelledDeleteRevokesWhatWaits", testCancelledDeleteRevokesWhatWaits),
            ("dictationWaitsLikeAKey", testDictationWaitsLikeAKey),
            ("hidingRunsWaitingKeysInTheirField", testHidingRunsWaitingKeysInTheirField),
            ("typingTorture", testTypingTorture),
        ]
    }

    /// A field whose context is all of it, and a probe across the emoji at its end that the host
    /// answers `callbackFrames` frames later.
    private static func emojiField(callbackFrames: Int = 3, unit: CursorOffsetUnit = .utf16) -> EditorHarness {
        EditorHarness(FakeTextHost(text: "Hi \u{1F44D}\u{1F3FD}", unit: unit, callbackFrames: callbackFrames))
    }

    private static func testKeysRunAtOnceWhileSettling() {
        // A gesture lifted while a move is still out and its reports are owed: a key settles it on the
        // spot and runs at once, where the move takes the caret.
        let harness = EditorHarness(FakeTextHost(text: "Alpha beta gamma", unit: .utf16, lagFrames: 1, callbackFrames: 3))
        harness.gesture(dx: -30, events: 1)
        TestSupport.expect(harness.trackpad.isActive, "settled before the key")
        TestSupport.expectEqual(harness.document.host.caret, 16)
        harness.press(.character("x"))
        TestSupport.expect(!harness.trackpad.isActive, "the gesture kept settling after a key")
        TestSupport.expect(harness.editor.pendingKeys.isEmpty, "the key waited")
        TestSupport.expectEqual(harness.document.text, "Alpha beta gaxmma")
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Alpha beta gaxmma")
    }

    private static func testShiftNeverOvertakesWaitingLetters() {
        // The round-6 review's P1: "a" queued behind settlement, Shift, "b" queued: the queue resolved its
        // closures after Shift had changed the state, and typed "Ab". Each key is resolved at its press.
        let harness = emojiField()
        harness.gesture(dx: -10, events: 1)
        TestSupport.expect(harness.trackpad.session?.hasOutstandingProbe == true, "no probe out")
        harness.press(.character("a"))
        harness.press(.shift)
        harness.press(.character("b"))
        TestSupport.expectEqual(harness.editor.pendingKeys.map(\.text), ["a", "B"])
        TestSupport.expectEqual(harness.document.text, "Hi \u{1F44D}\u{1F3FD}")
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Hi aB\u{1F44D}\u{1F3FD}")
        TestSupport.expectEqual(harness.trackpad.session == nil, true)
    }

    private static func testOwnTypingReportsNeverDropKeys() {
        // The round-6 review's P1: a, b, c queued; the host reported a's insertion between frames, the
        // report was an outside change, and b and c were discarded. Our own edits' reports, delayed or
        // coalesced, are never outside changes, and keys no longer wait in a queue they could be
        // discarded from.
        for delay in [1, 2, 3] {
            // Waiting on a probe, then run together.
            let waiting = emojiField()
            waiting.document.editCallbackDelay = delay
            waiting.gesture(dx: -10, events: 1)
            waiting.type("abc")
            waiting.settle()
            TestSupport.expectEqual(waiting.document.text, "Hi abc\u{1F44D}\u{1F3FD}")
            TestSupport.expect(!waiting.outcomes.contains(.outside), "an own report taken as outside at \(delay)")
            // Typed one per frame, each report arriving between later keys.
            let typed = EditorHarness(FakeTextHost(text: "Notes: ", model: .uikit), editCallbackDelay: delay)
            for character in "abc" {
                typed.press(.character(String(character)))
                typed.frame()
            }
            typed.press(.delete)
            typed.type(" d")
            typed.settle()
            TestSupport.expectEqual(typed.document.text, "Notes: ab d")
            TestSupport.expect(!typed.outcomes.contains(.outside), "an own report taken as outside at \(delay)")
            TestSupport.expect(typed.outcomes.contains(.ownEdit), "no own report delivered at \(delay)")
        }
    }

    private static func testOwnTypingReportsNeverEndTheNextGesture() {
        // Typing, then a gesture before the host's reports of it arrive: they are our own edits, not an
        // outside change that would end the gesture.
        let harness = EditorHarness(FakeTextHost(text: "One two three", unit: .utf16), editCallbackDelay: 3)
        harness.type(" four")
        harness.gesture(dx: 0, events: 2, lift: false)
        TestSupport.expect(harness.trackpad.isActive, "the gesture ended")
        harness.trackpad.move(dx: -30, dy: 0, timestamp: harness.time)
        harness.frames(4)
        harness.trackpad.end(at: harness.time)
        harness.settle()
        TestSupport.expect(!harness.outcomes.contains(.outside), "an own report ended the gesture")
        TestSupport.expectEqual(harness.document.host.caret, "One two three f".utf16.count)
    }

    private static func testKeyReleasedAfterTheFieldChangedNeverLands() {
        // The round-6 review's P1: a letter pressed in field A; the proxy served field B before any
        // callback said so; the release typed into B. Each key is bound to the field of its press.
        let harness = EditorHarness(FakeTextHost(text: "Field A.", model: .uikit))
        let fieldA = harness.field
        harness.document.switchField(to: FakeTextHost(text: "Field B.", model: .uikit), id: UUID())
        for action in [KeyAction.character("x"), .space, .returnKey, .delete] {
            harness.press(action, field: fieldA)
        }
        TestSupport.expectEqual(harness.document.text, "Field B.")
        // Pressed in B, it types in B.
        harness.press(.character("y"))
        TestSupport.expectEqual(harness.document.text, "Field B.y")
    }

    private static func testWaitingKeysStopAfterAReturn() {
        // Keys waiting on a probe include a Return that moves the host to field B: the keys after it run
        // a frame later, bound to field A, so nothing lands in B.
        let harness = emojiField()
        let fieldB = FakeTextHost(text: "Field B.", model: .uikit)
        harness.document.returnMovesFocusTo = (fieldB, UUID())
        harness.gesture(dx: -10, events: 1)
        harness.type("x\nyz")
        TestSupport.expectEqual(harness.editor.pendingKeys.count, 4)
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Field B.")
        TestSupport.expectEqual(harness.document.previousHosts.last?.text, "Hi x\n\u{1F44D}\u{1F3FD}")
        // Without the focus change, everything lands in order.
        let staying = emojiField()
        staying.gesture(dx: -10, events: 1)
        staying.type("x\nyz")
        staying.settle()
        TestSupport.expectEqual(staying.document.text, "Hi x\nyz\u{1F44D}\u{1F3FD}")
    }

    private static func testAbortWhileKeysWaitRepairsTheSplitFirst() {
        // A probe left a UTF-16 caret between "e" and its accent; the gesture ends before its outcome is
        // read (an outside change, say). The keys still run, but never inside the cluster.
        let harness = EditorHarness(FakeTextHost(text: "e\u{301}", unit: .utf16, callbackFrames: 5))
        harness.gesture(dx: -10, events: 1)
        TestSupport.expect(harness.trackpad.session?.hasOutstandingProbe == true, "no probe out")
        TestSupport.expectEqual(harness.document.host.caret, 1)
        harness.press(.character("x"))
        TestSupport.expectEqual(harness.document.text, "e\u{301}")
        harness.trackpad.abort()
        TestSupport.expectEqual(harness.document.text, "xe\u{301}")
    }

    private static func testKeysWaitForTheWholeClusterRepair() {
        // Found by the typing torture test: a jump past the edge stopped between the halves of a surrogate
        // pair; its repair out of the pair reaches only the next scalar, still inside "👍🏽". A key pressed
        // then waits until the caret is on the cluster's edge.
        let harness = EditorHarness(FakeTextHost(text: "ab\u{1F44D}\u{1F3FD}cd\nnext line", caret: 0, unit: .utf16, window: 2))
        harness.editor.beginTrackpad(layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000,
                                     now: harness.time)
        var pressed = false
        for _ in 0 ..< 40 where !pressed {
            harness.trackpad.move(dx: 0, dy: 0.5, timestamp: harness.time)
            harness.frame()
            let host = harness.document.host
            if !host.caretIsOnBoundary, !host.caretSplitsSurrogatePair {
                harness.trackpad.end(at: harness.time)
                harness.press(.character("Q"))
                pressed = true
            }
        }
        TestSupport.expect(pressed, "the repair never stopped between the scalars")
        harness.settle()
        TestSupport.expect(harness.document.text.contains("\u{1F44D}\u{1F3FD}"), "the emoji was split: \(harness.document.text)")
        TestSupport.expectEqual(harness.document.text.replacingOccurrences(of: "Q", with: ""), "ab\u{1F44D}\u{1F3FD}cd\nnext line")
    }

    private static func testCancelledDeleteRevokesWhatWaits() {
        // The fourth review's P1, now for deletions waiting on a probe: a cancelled press revokes them;
        // what was typed with them still runs.
        let harness = emojiField()
        harness.gesture(dx: -10, events: 1)
        harness.editor.heldDelete(.character, token: 7, field: harness.field, now: harness.time)
        harness.type("ab")
        harness.editor.revoke(token: 7)
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Hi ab\u{1F44D}\u{1F3FD}")
    }

    private static func testDictationWaitsLikeAKey() {
        let harness = emojiField()
        harness.gesture(dx: -10, events: 1)
        harness.press(.character("a"))
        harness.editor.insertDictation(" invented words", now: harness.time)
        harness.press(.character("b"))
        harness.settle()
        TestSupport.expectEqual(harness.document.text, "Hi a invented wordsb\u{1F44D}\u{1F3FD}")
    }

    private static func testHidingRunsWaitingKeysInTheirField() {
        let harness = emojiField()
        harness.gesture(dx: -10, events: 1)
        harness.type("ab")
        harness.editor.hide(now: harness.time)
        TestSupport.expect(harness.editor.pendingKeys.isEmpty, "keys kept after hiding")
        TestSupport.expect(harness.document.text.contains("ab"), "keys dropped on hiding: \(harness.document.text)")
        TestSupport.expectEqual(harness.document.text.replacingOccurrences(of: "ab", with: ""), "Hi \u{1F44D}\u{1F3FD}")
    }

    // MARK: Torture

    /// The document a sequence of keys makes when each is applied in order at the caret, with the shift
    /// state of its press. The caret follows the trackpad where each session left it.
    private struct TypingModel {
        /// A key's effect on the text, decided at its press.
        enum Edit { case insert(String), delete }

        var text: String
        var caret: Int
        var shift = false
        /// Keys pressed while the trackpad resolves a probe: applied where its session leaves the caret.
        var waiting: [Edit] = []

        /// The key's edit, with the shift state of its press.
        mutating func resolve(_ action: KeyAction) -> Edit? {
            switch action {
            case .character(let character):
                defer { shift = false }
                return .insert(shift ? character.uppercased() : character)
            case .space: return .insert(" ")
            case .returnKey: return .insert("\n")
            case .delete: return .delete
            case .shift:
                shift.toggle()
                return nil
            case .layer, .nextKeyboard:
                return nil
            }
        }

        /// A session ended with the caret at `caret`: keys that waited on it go there.
        mutating func sessionEnded(caret: Int) {
            self.caret = caret
            for edit in waiting { apply(edit) }
            waiting = []
        }

        mutating func apply(_ edit: Edit) {
            switch edit {
            case .insert(let inserted):
                insert(inserted)
            case .delete:
                var offsets = [0], offset = 0
                for character in text {
                    offset += character.utf16.count
                    offsets.append(offset)
                }
                guard caret > 0 else { return }
                let start = offsets.last { $0 < caret } ?? 0
                let units = Array(text.utf16)
                text = String(decoding: units[..<start], as: UTF16.self) + String(decoding: units[caret...], as: UTF16.self)
                caret = start
            }
        }

        private mutating func insert(_ inserted: String) {
            let units = Array(text.utf16)
            text = String(decoding: units[..<caret], as: UTF16.self) + inserted + String(decoding: units[caret...], as: UTF16.self)
            caret += inserted.utf16.count
        }
    }

    private static func testTypingTorture() {
        // Long random sequences of characters (emoji and combining marks included), shift, space,
        // delete and return, interleaved with trackpad gestures, lifts and settling, probes still out,
        // lagging adjustments, WebKit's double reports and our own edits' reports delayed and
        // coalesced. The document must always be the keys applied in press order.
        let characters = ["a", "k", "z", "\u{E9}", "e\u{301}", "\u{1F44D}\u{1F3FD}", "\u{DF}", ",", "Q"]
        for seed in UInt64(1) ... 60 {
            var random = SplitMix64(seed: seed)
            let unit: CursorOffsetUnit = random.chance(0.5) ? .utf16 : .grapheme
            let callbackFrames = random.pick([nil, 1, 2, 3])
            // A proxy answers provisionally only until the host's report replaces it; a host that never
            // reports would leave it stale for good.
            var host = FakeTextHost(text: "Seed text \u{1F44D} here.", unit: unit,
                                    model: random.chance(0.5) ? .uikit : .whole,
                                    lagFrames: random.below(3), callbackFrames: callbackFrames,
                                    provisionalContext: callbackFrames != nil && random.chance(0.5))
            host.reportsAsIssuedFirst = unit == .grapheme && random.chance(0.5)
            let harness = EditorHarness(host, editCallbackDelay: random.pick([nil, 1, 2, 3]))
            var model = TypingModel(text: host.text, caret: host.caret)
            harness.onSessionEnd = { [unowned harness] completed in
                harness.document.host.applyQueuedAdjustments()
                model.sessionEnded(caret: harness.document.host.caret)
                if completed {
                    TestSupport.expect(harness.document.host.caretIsOnBoundary,
                                       "seed \(seed): a settled gesture left the caret inside a cluster")
                }
            }
            var last: KeyAction?
            for _ in 0 ..< 250 {
                switch random.below(10) {
                case 0 ..< 6:
                    var action: KeyAction
                    switch random.below(10) {
                    case 0: action = .space
                    case 1: action = .delete
                    case 2: action = .returnKey
                    case 3: action = .shift
                    default: action = .character(random.pick(characters))
                    }
                    // Two spaces or two shift taps in a row are other features (". ", caps lock).
                    if action == last, action == .space || action == .shift { action = .character("m") }
                    harness.press(action)
                    if let edit = model.resolve(action) {
                        if harness.trackpad.isSettlingForTyping { model.waiting.append(edit) } else { model.apply(edit) }
                    }
                    last = action
                case 6 ..< 8:
                    harness.frames(1 + random.below(3))
                default:
                    harness.gesture(dx: Double(random.below(41)) - 20, dy: Double(random.below(21)) - 10,
                                    events: 1 + random.below(6))
                    harness.frames(random.below(4))
                    last = nil
                }
                TestSupport.expectEqual(harness.document.documentID, harness.field)
            }
            harness.settle()
            TestSupport.expect(harness.document.text == model.text,
                               "seed \(seed): \(harness.document.text.debugDescription) != \(model.text.debugDescription)")
        }
    }

}

/// The keyboard's editing side against a fake field, as `KeyboardInput` and `TrackpadDriver` drive it.
final class EditorHarness {
    let document: FakeDocument
    let trackpad: TrackpadController
    let editor: KeyboardEditor
    private(set) var time: TimeInterval = 100
    private(set) var outcomes: [EditingCore.CallbackOutcome] = []
    /// A session ended (completed or not), before the keys waiting on it run.
    var onSessionEnd: ((Bool) -> Void)?

    init(_ host: FakeTextHost, autocapitalization: AutocapitalizationMode = .none, editCallbackDelay: Int? = nil) {
        document = FakeDocument(host)
        document.editCallbackDelay = editCallbackDelay
        trackpad = TrackpadController(host: document)
        trackpad.parameters = .flat
        editor = KeyboardEditor(document: document, trackpad: trackpad)
        editor.autocapitalization = { autocapitalization }
        let finished = trackpad.onFinished
        trackpad.onFinished = { [weak self] completed in
            self?.onSessionEnd?(completed)
            finished?(completed)
        }
        editor.reset(numeric: false)
    }

    var field: UUID? { document.documentID }

    /// One display frame: due host events and callbacks reach the editor, keys stopped after a Return
    /// on an earlier frame go on (the keyboard's timer), then the trackpad's frame.
    func frame() {
        time += 1.0 / 120
        document.host.advanceFrame()
        while document.host.takeCallback() != nil {
            outcomes.append(editor.hostChanged(textChanged: true, now: time))
        }
        outcomes += document.pump(editor, at: time)
        editor.continuePendingKeys(now: time)
        trackpad.tick(at: time)
    }

    func frames(_ count: Int) {
        for _ in 0 ..< count { frame() }
    }

    /// A key, pressed in `field` (the current one unless given).
    func press(_ action: KeyAction, field: UUID?? = .none) {
        editor.press(action, field: field ?? document.documentID, at: time, now: time)
    }

    func type(_ text: String) {
        for character in text {
            switch character {
            case " ": press(.space)
            case "\n": press(.returnKey)
            default: press(.character(String(character)))
            }
        }
    }

    /// A gesture: touch-down, one touch event per frame, then the lift (unless `lift` is false). Keys
    /// may follow at once.
    func gesture(dx: Double = 0, dy: Double = 0, events: Int, lift: Bool = true) {
        editor.beginTrackpad(layout: FixedWidthLayout(columns: 1_000), linePitch: 20, layoutWidth: 10_000, now: time)
        for _ in 0 ..< events {
            trackpad.move(dx: dx, dy: dy, timestamp: time)
            frame()
        }
        if lift { trackpad.end(at: time) }
    }

    /// Frames until nothing is left to happen: no session, no waiting keys, no callbacks to come.
    func settle(maxFrames: Int = 600) {
        for _ in 0 ..< maxFrames where trackpad.isActive || !editor.pendingKeys.isEmpty || document.pendingCallbacks > 0
            || document.host.hasCallbacksToCome {
            frame()
        }
    }
}

/// A small deterministic generator for randomized tests (SplitMix64).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double(next() % 1_000_000) / 1_000_000 < probability
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[below(values.count)]
    }
}
