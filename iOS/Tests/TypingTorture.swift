import Foundation

/// The typing torture test (ARCHITECTURE.md, "Typing model v2: immediate execution"): a seeded script of
/// touches (taps, holds, rollover; shift, caps lock, layers; space, double space, return, delete),
/// trackpad gestures (keys at the lift, letters while a probe is out, Shift and layer keys among them,
/// outside changes and hiding while one settles), focus changes between two fields (keys typed before
/// the new field's first callback, fingers held across), fields without an identity (fingers held
/// through nil → A → B), hiding, the host app's own edits, caret moves and selections, against hosts with
/// lagging adjustments, short, long or missing callbacks, WebKit's double reports and proxy contexts that
/// lag the keyboard's edits. Documents are compared as UTF-16 code units, as UIKit keeps them.
///
/// The oracle computes the expected documents, carets, selections, shift and layer from the script
/// alone, with its own statement of the contract's rules (`OracleRules`, `OracleTyping`): a key edits the
/// field the proxy serves the moment it is released (a held key is committed in press order when
/// another touches down), with the shift and layer of that moment, unless it was pressed in another
/// identified field; casing and the double-space period follow the text before the caret. Every edit is
/// checked right after its release. A gesture whose target the script knows (a whole-context field, a
/// span of one-unit characters) lands exactly there, keys at its lift included. For a free gesture a key
/// interrupted, only where the first key acts comes from the host (its caret once what the gesture issued
/// has landed, inside a cluster too: the accepted residual); the shift there follows what the keyboard can
/// read (the gesture's landing, or the proxy when a probe's outcome is abandoned), and every key is
/// checked exactly, case included. A gesture no key interrupted ends on a character boundary, with the
/// text unchanged but for an outside change. Every step that needs the keyboard settled fails when it
/// never settles. Deterministic per seed.
struct TypingTorture {
    struct Failure: Equatable {
        var step: Int
        var message: String
    }

    let seed: UInt64

    /// Runs `steps` steps of the seed's script, comparing whenever a step leaves the keyboard settled (and
    /// at the end); nil if everything matched.
    func run(steps: Int) -> Failure? {
        let world = TortureWorld(seed: seed)
        for step in 1 ... max(steps, 1) {
            if let message = world.step() { return Failure(step: step, message: message + "\n  " + world.recentEvents) }
        }
        if let message = world.finish() { return Failure(step: steps, message: message + "\n  " + world.recentEvents) }
        return nil
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
        Int(next() % UInt64(max(bound, 1)))
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double(next() % 1_000_000) / 1_000_000 < probability
    }

    mutating func pick<T>(_ values: [T]) -> T {
        values[below(values.count)]
    }
}

/// The contract's casing and double-space rules, stated for the oracle on its own (not the keyboard's
/// helpers).
private enum OracleRules {
    /// Two shift taps this close turn on caps lock; the second space of ". " follows the first this soon.
    static let shiftDoubleTap: TimeInterval = 0.35
    static let doubleSpace: TimeInterval = 3

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "\u{2026}"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "\u{201D}", "\u{2019}", "\u{00BB}"]

    /// Whether the next letter is capitalized, from the text before the caret.
    static func capitalizes(after before: String, mode: AutocapitalizationMode) -> Bool {
        switch mode {
        case .none: return false
        case .allCharacters: return true
        case .words: return before.last.map { $0.isWhitespace } ?? true
        case .sentences:
            // The field's start, a new line, or spaces after a sentence's end (closing quotes and brackets
            // may come between).
            var rest = Substring(before)
            guard let last = rest.last else { return true }
            if last.isNewline { return true }
            guard last == " " || last == "\t" else { return false }
            while rest.last == " " || rest.last == "\t" { rest = rest.dropLast() }
            guard let end = rest.last else { return true }
            if end.isNewline { return true }
            while let character = rest.last, closers.contains(character) { rest = rest.dropLast() }
            return rest.last.map { sentenceEnds.contains($0) } ?? false
        }
    }

    /// Whether the shift after `typed` is the same whatever text comes before it.
    static func decides(_ typed: String, mode: AutocapitalizationMode) -> Bool {
        let first = capitalizes(after: typed, mode: mode)
        return ["a", "a ", "a. ", "a.\n", "\n", " "].allSatisfy { capitalizes(after: $0 + typed, mode: mode) == first }
    }

    /// Whether a second space replaces the first with ". ": it follows a letter, a digit or a closing
    /// quote or bracket.
    static func periodReplaces(spaceAfter before: String) -> Bool {
        guard before.last == " ", let previous = before.dropLast().last else { return false }
        return previous.isLetter || previous.isNumber || closers.subtracting(["\u{00BB}"]).contains(previous)
    }
}

/// The keyboard's typing state as the contract describes it, kept by the oracle.
private struct OracleTyping {
    var layer = KeyboardLayer.letters
    var shift = ShiftMode.off
    /// The shift came on by auto-capitalization (so auto-capitalization may turn it off).
    var automatic = false
    var lastShiftTap: TimeInterval?
    var lastSpace: TimeInterval?
    /// What the text last called for: auto-capitalization acts only when that changes, or after an edit,
    /// a field change or a callback that is not an echo of our own edits.
    var decision: Bool?

    mutating func tapShift(at time: TimeInterval) {
        if let last = lastShiftTap, time >= last, time - last <= OracleRules.shiftDoubleTap {
            shift = .capsLock
            lastShiftTap = nil
        } else {
            shift = shift == .off ? .once : .off
            lastShiftTap = time
        }
        automatic = false
        lastSpace = nil
    }

    mutating func switchLayer(_ to: KeyboardLayer) {
        layer = to
        lastSpace = nil
        lastShiftTap = nil
    }

    /// A key's edit: graphemes deleted before the caret, then text inserted.
    mutating func resolve(_ action: KeyAction, before: String, at time: TimeInterval) -> (deletes: Int, text: String) {
        switch action {
        case .character(let character):
            let text = shift == .off ? character : character.uppercased()
            if shift == .once {
                shift = .off
                automatic = false
            }
            if layer != .letters, text == "'" { layer = .letters }
            lastSpace = nil
            lastShiftTap = nil
            decision = nil
            return (0, text)
        case .space:
            lastShiftTap = nil
            decision = nil
            defer { layer = .letters }
            if let last = lastSpace, time >= last, time - last <= OracleRules.doubleSpace,
               OracleRules.periodReplaces(spaceAfter: before) {
                lastSpace = nil
                return (1, ". ")
            }
            lastSpace = time
            return (0, " ")
        case .returnKey:
            layer = .letters
            lastSpace = nil
            lastShiftTap = nil
            decision = nil
            return (0, "\n")
        case .delete:
            lastSpace = nil
            lastShiftTap = nil
            decision = nil
            return (1, "")
        case .shift, .layer, .nextKeyboard:
            return (0, "")
        }
    }

    /// Auto-capitalization moves only between off and an automatic one-shot shift, and never overrides
    /// a shift the user set or caps lock.
    mutating func update(_ capitalizes: Bool) {
        guard capitalizes != decision else { return }
        decision = capitalizes
        if capitalizes, shift == .off {
            shift = .once
            automatic = true
        } else if !capitalizes, shift == .once, automatic {
            shift = .off
            automatic = false
        }
    }

    mutating func resetTiming() {
        lastSpace = nil
        lastShiftTap = nil
        decision = nil
    }
}

/// A field as the oracle expects it, in UTF-16 code units as the host keeps it: a key inside a surrogate
/// pair (the accepted residual) leaves both halves, and deleting it rejoins them.
private struct OracleField {
    var units: [UInt16]
    var caret: Int
    var selection = 0

    /// As a Swift string: a lone surrogate half reads as U+FFFD, one unit, so offsets agree.
    var text: String { String(decoding: units, as: UTF16.self) }

    var before: String { String(decoding: units[..<min(caret, units.count)], as: UTF16.self) }

    /// UTF-16 offsets of every character boundary.
    var boundaries: [Int] {
        var offsets = [0], offset = 0
        for character in text {
            offset += character.utf16.count
            offsets.append(offset)
        }
        return offsets
    }

    /// The host's own semantics: delete the selection, or back to the character boundary before the
    /// caret; insert in place of the selection.
    mutating func apply(deletes: Int, text inserted: String) {
        for _ in 0 ..< deletes {
            if selection > 0 {
                units.removeSubrange(caret ..< caret + selection)
                selection = 0
            } else {
                guard caret > 0 else { continue }
                let start = boundaries.last { $0 < caret } ?? 0
                units.removeSubrange(start ..< caret)
                caret = start
            }
        }
        guard !inserted.isEmpty else { return }
        units.replaceSubrange(caret ..< caret + selection, with: Array(inserted.utf16))
        caret += inserted.utf16.count
        selection = 0
    }
}

/// The script, the keyboard under test, and the oracle, in lockstep.
private final class TortureWorld {
    private var random: SplitMix64
    private let harness: KeyboardHarness
    private let ids: [UUID]
    private var parked: [UUID: FakeTextHost] = [:]
    private var modes: [UUID: AutocapitalizationMode] = [:]
    private var wholeContext: [UUID: Bool] = [:]
    private var fields: [UUID: OracleField] = [:]
    private var typing = OracleTyping()
    /// The identity the proxy reports (nil during a transition), the field it shows, and the identity the
    /// keyboard last took as current (by a callback, or for a key typed before one).
    private var current: UUID?
    private var shown: UUID
    private var keyboardField: UUID?
    private var lastKey: KeyAction?
    /// What the script did lately, for a failure's message.
    private var log: [String] = []
    /// `TORTURE_TRACE=1`: every event also shows the keyboard's and the oracle's view, and every frame
    /// of a gesture the host's (invented text only), for debugging a failing seed.
    private let tracing = ProcessInfo.processInfo.environment["TORTURE_TRACE"] != nil
    private var inGesture = false
    private var logLimit: Int { tracing ? 2_000 : 40 }
    private var lastKeyAt: TimeInterval = -.infinity
    /// The first disagreement seen right after an edit, reported at the end of the step.
    private var failure: String?
    /// Host callbacks delivered while no gesture ran: none is a gesture's own report, and the torture's
    /// host never echoes our edits, so each one starts the space and shift timing over.
    private var freeDeliveries = 0
    /// While the keys typed after a key ended a free gesture run: the field's text before this offset is
    /// text the keyboard has not been shown. With a probe or a jump abandoned that is all of it before the
    /// first key's insertion point, since the proxy's reading may not show where the host had the caret;
    /// with the gesture's landing known, the text before the window the proxy showed. A caret at or before
    /// it (deletions reach there) is cased from the proxy's context, which, on a host that shows our edits
    /// at once, is the field's own text there; everything typed after it is cased from the field's text.
    private var unknown: Int?
    /// From a key ending a free gesture until the first edit: the text before the caret as the keyboard
    /// reads it then (the landing, or the proxy's reading), which Shift and layer keys before that edit see.
    private var interruptContext: String?
    /// The spans of the field the proxy showed as they are during the current gesture (`FakeTextHost
    /// .liveWindow`), oldest first: what the keyboard could have read, observed without asking it.
    private var windowsSeen: [Range<Int>] = []
    /// While the keys after a free gesture on a slow host run (reports after `syncTimeout`, or edits shown
    /// late): the field's text before this offset (the first key's insertion point, or where deletions
    /// since reached) may never have been shown as it is. A letter whose case depends on it is taken from
    /// the host; where the keys act, and that each acts once, in order, is still checked exactly.
    private var slowBase: Int?

    private func note(_ event: String) {
        var line = String(format: "%.3f ", time - 100) + event
        if tracing {
            line += " [keyboard \(harness.editor.typing.shift) reads \(String((harness.editor.currentBefore ?? "").suffix(8)).debugDescription)"
                + ", oracle \(typing.shift) \(String(fields[shown]!.before.suffix(8)).debugDescription)]"
        }
        log.append(line)
        if log.count > logLimit { log.removeFirst(log.count - logLimit) }
    }

    var recentEvents: String { log.suffix(tracing ? 2_000 : 24).joined(separator: "\n  ") }

    init(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        let ids = [UUID(), UUID()]
        let texts = ["Seed text \u{1F44D} here.\nSecond line e\u{301} too.", "Other field. Hi"]
        var hosts: [FakeTextHost] = []
        var modes: [UUID: AutocapitalizationMode] = [:]
        var wholeContext: [UUID: Bool] = [:]
        var fields: [UUID: OracleField] = [:]
        for (index, id) in ids.enumerated() {
            let unit: CursorOffsetUnit = random.chance(0.5) ? .utf16 : .grapheme
            let model: FakeContextModel = random.chance(0.5) ? .whole : random.pick([.uikit, .lineBreakOnly])
            // Reports from one frame to well past the trackpad's `syncTimeout`, or none.
            let callbackFrames = random.pick([nil, 1, 2, 3, 20, 30, 45] as [Int?])
            // A proxy answers provisionally until the host's report replaces it, so a lagging host needs
            // reports and a provisional answer; a host that never reports never leaves one stale.
            let lag = callbackFrames == nil ? 0 : random.below(4)
            let provisional = callbackFrames != nil && (lag > 0 || random.chance(0.5))
            var host = FakeTextHost(text: texts[index], unit: unit, model: model, lagFrames: lag,
                                    callbackFrames: callbackFrames, provisionalContext: provisional)
            host.reportsAsIssuedFirst = unit == .grapheme && callbackFrames != nil && random.chance(0.5)
            // A host that shows the keyboard's edits late shows text past a line break (a residual: where
            // the proxy shows only the break at a line start, a key typed within that lag after deleting
            // the break cannot know the text before it, and is cased by the stale break).
            let lagsEdits = random.chance(0.25) && model != .lineBreakOnly
            host.editContextLagFrames = lagsEdits ? 1 + random.below(3) : 0
            hosts.append(host)
            modes[id] = random.pick([AutocapitalizationMode.sentences, .sentences, .none, .words, .allCharacters])
            wholeContext[id] = model == .whole
            fields[id] = OracleField(units: host.units, caret: host.caret)
        }
        self.random = random
        self.ids = ids
        self.modes = modes
        self.wholeContext = wholeContext
        self.fields = fields
        parked = [ids[1]: hosts[1]]
        current = ids[0]
        shown = ids[0]
        keyboardField = ids[0]
        harness = KeyboardHarness(hosts[0], autocapitalization: modes[ids[0]]!, documentID: ids[0])
        update()
        harness.onDeliver = { [unowned self] gestureRunning in
            if !gestureRunning { self.freeDeliveries += 1 }
        }
        harness.onFrame = { [unowned self] in
            guard self.inGesture else { return }
            let host = self.harness.document.host
            if let window = host.liveWindow, self.windowsSeen.last != window { self.windowsSeen.append(window) }
            if self.tracing {
                self.note("frame: trackpad \(self.harness.trackpad.isActive ? "on" : "off") unit \(self.harness.trackpad.session?.unit.map { "\($0)" } ?? "-"), caret \(host.caret), proxy "
                    + "\(String((self.harness.document.contextBefore ?? "").suffix(8)).debugDescription), \(host.traceDescription), "
                    + "outcomes \(self.harness.outcomes.suffix(2))")
            }
        }
    }

    private var time: TimeInterval { harness.time }

    // MARK: Steps

    /// One step of the script; a message if the keyboard and the oracle disagree.
    func step() -> String? {
        let message: String?
        switch random.below(100) {
        case 0 ..< 40: message = keyStep()
        case 40 ..< 48:
            harness.frames(1 + random.below(4))
            message = nil
        case 48 ..< 64: message = gestureStep()
        case 64 ..< 70: message = hostEditStep()
        case 70 ..< 77: message = focusStep()
        case 77 ..< 82: message = unidentifiedStep()
        case 82 ..< 87: message = deleteHoldStep()
        case 87 ..< 91: message = hideStep()
        default: message = shiftOrLayerStep()
        }
        if let message { return message }
        if let failure { return failure }
        // Half the time, everything settles and is compared; otherwise the next step interleaves.
        return random.chance(0.5) ? settleAndCheck() : nil
    }

    /// Lets everything settle, then compares.
    func finish() -> String? {
        settleAndCheck()
    }

    /// Frames until the keyboard is settled: no session, no callbacks to come, no touches or timers, and
    /// the proxy showing the field as it is. False if it never gets there.
    private func quiet(maxFrames: Int = 1_200) -> Bool {
        for _ in 0 ..< maxFrames {
            if harness.isQuiet { return true }
            harness.frame()
        }
        return harness.isQuiet
    }

    private func settleAndCheck() -> String? {
        if let failure { return failure }
        guard quiet() else { return "the keyboard never settled" }
        return failure ?? check()
    }

    /// Right after a key's release (or its rollover commit, or a held delete's deletion): the field the
    /// proxy serves already holds the edit, at the oracle's caret (ARCHITECTURE.md, "Typing model v2":
    /// keys execute immediately). The first disagreement is kept for the step's result.
    private func verify(after event: String) {
        guard failure == nil else { return }
        let host = harness.document.host, expected = fields[shown]!
        if host.units != expected.units {
            failure = "right after \(event), field \(name(shown)): \(host.text.debugDescription) != expected \(expected.text.debugDescription)"
        } else if host.caret != expected.caret || host.selectionLength != expected.selection {
            failure = "right after \(event), field \(name(shown)): caret \(host.caret)+\(host.selectionLength) != expected "
                + "\(expected.caret)+\(expected.selection)"
        }
    }

    // MARK: Keys

    private func keys(_ filter: (KeyAction) -> Bool) -> [KeyAction] {
        harness.model.keys.map(\.action).filter(filter)
    }

    private func typedKeys(space: Bool = true) -> [KeyAction] {
        keys { action in
            switch action {
            case .character, .returnKey: return true
            case .space: return space
            default: return false
            }
        }
    }

    private func keyStep() -> String? {
        var action = random.chance(0.12) ? KeyAction.space : random.pick(typedKeys())
        // Two spaces in a row are kept (". "), but not three.
        if action == .space, lastKey == .space, random.chance(0.5) { action = random.pick(typedKeys()) }
        switch random.below(10) {
        case 0:
            // Rollover: a second finger lands while the first is down, then both lift.
            let first = touchDown(action)
            let next = touchDown(random.pick(typedKeys()))
            touchUp(next)
            touchUp(first)
        case 1:
            // A hold, then the lift.
            let id = touchDown(action)
            harness.frames(1 + random.below(10))
            touchUp(id)
        default:
            touchUp(touchDown(action))
        }
        return nil
    }

    private func shiftOrLayerStep() -> String? {
        note("shift or layer")
        let layers = keys { if case .layer = $0 { return true } else { return false } }
        if random.chance(0.6), keys({ $0 == .shift }).count == 1 {
            touchUp(touchDown(.shift))
            // Sometimes the second tap of a double tap: caps lock.
            if random.chance(0.3) {
                harness.frames(random.below(3))
                touchUp(touchDown(.shift))
            }
        } else if let layer = layers.randomElement(using: &random) {
            touchUp(touchDown(layer))
        }
        return nil
    }

    private func deleteHoldStep() -> String? {
        note("delete hold")
        let id = touchDown(.delete)
        // Released before the first deletion (0.12 s), or after it and before the first repeat (0.6 s).
        let frames = random.chance(0.5) ? random.below(10) : 20 + random.below(30)
        for frame in 0 ..< frames {
            harness.frame()
            // The first deletion fires on the frame at or after 0.12 s.
            if frame + 1 == Int((DeleteRepeatParameters.standard.firstDeletionDelay * 120).rounded(.up)) { deleteFired() }
        }
        touchUp(id)
        return nil
    }

    // MARK: Touches, as the key area does

    private enum Role { case character, space, returnKey, other }

    private struct Held {
        var action: KeyAction?
        var role: Role
        var field: UUID?
        var committed = false
        var x: Double
        var y: Double
    }

    private var bindings: [KeyTouchModel.TouchID: Held] = [:]
    private var deleteBinding: UUID?
    private var deleteDone = false
    /// The layer the key area's keys were last laid out for.
    private var layoutLayer = KeyboardLayer.letters

    private func touchDown(_ action: KeyAction) -> KeyTouchModel.TouchID {
        guard let point = harness.center(action) else { preconditionFailure("the script pressed \(action), not shown") }
        // A new finger commits every earlier one still held: characters, space and return.
        var committed = false
        for (id, held) in bindings.sorted(by: { $0.key < $1.key }) where !held.committed {
            switch (held.role, held.action) {
            case (.character, .character?), (.space, .space?), (.returnKey, .returnKey?):
                bindings[id]?.committed = true
                type(held.action!, binding: held.field, verifying: false)
                committed = true
            default:
                break
            }
        }
        let id = harness.touchDown(action)
        if committed { verify(after: "rollover") }
        let role: Role
        switch action {
        case .character: role = .character
        case .space: role = .space
        case .returnKey: role = .returnKey
        default: role = .other
        }
        bindings[id] = Held(action: action, role: role, field: current, x: point.x, y: point.y)
        switch action {
        case .shift:
            note("key down shift (keyboard: \(harness.editor.typing.shift), oracle before: \(typing.shift))")
            typing.tapShift(at: time)
        case .layer(let layer):
            typing.switchLayer(layer)
            update()
        case .delete:
            deleteBinding = current
            deleteDone = false
        default:
            break
        }
        remapHeldKeys()
        return id
    }

    /// A layer change re-lays the keys out: a held character finger now presses the key under it.
    private func remapHeldKeys() {
        guard typing.layer != layoutLayer else { return }
        layoutLayer = typing.layer
        let keys = KeyboardLayout.keys(for: layoutLayer, metrics: KeyboardHarness.metrics, showsGlobe: false)
        for (id, held) in bindings where !held.committed {
            switch held.role {
            case .character:
                bindings[id]?.action = KeyboardLayout.nearestKey(toX: held.x, y: held.y, in: keys).map { keys[$0].action }
            case .space, .returnKey, .other:
                if let action = held.action, !keys.contains(where: { $0.action == action }) { bindings[id]?.action = nil }
            }
        }
    }

    private func touchUp(_ id: KeyTouchModel.TouchID) {
        guard let held = bindings.removeValue(forKey: id) else { return harness.touchUp(id) }
        harness.touchUp(id)
        guard !held.committed else { return }
        switch (held.role, held.action) {
        case (.character, .character?), (.space, .space?), (.returnKey, .returnKey?):
            type(held.action!, binding: held.field)
        case (.other, .delete?):
            // A release before the first deletion deletes once, unless another identified field is current.
            guard !deleteDone else { break }
            deleteDone = true
            type(.delete, binding: deleteBinding)
        default:
            break
        }
        remapHeldKeys()
    }

    /// The held delete key's first deletion, while it is held.
    private func deleteFired() {
        guard bindings.values.contains(where: { $0.action == .delete }) else { return }
        if let bound = deleteBinding, let field = current, bound != field {
            // In another identified field the press ends, deleting nothing (now or at its release).
            deleteDone = true
            return
        }
        if deleteBinding == nil { deleteBinding = current }
        deleteDone = true
        type(.delete, binding: deleteBinding)
    }

    /// A key reaches the editor: pressed in another identified field, it is cancelled; otherwise it edits
    /// the field the proxy serves, now. A field the proxy serves before its first callback is taken as
    /// current first.
    private func type(_ action: KeyAction, binding: UUID?, verifying: Bool = true) {
        defer { if verifying { verify(after: "\(action)") } }
        lastKey = action
        lastKeyAt = time
        note("key \(action) bound \(name(binding)) in \(name(current)) shift \(typing.shift) (keyboard: \(harness.editor.typing.shift)) layer \(typing.layer)")
        if let bound = binding, let field = current, bound != field { return }
        if current != keyboardField { fieldChanged() }
        // On a slow host, the case of a letter typed where the shift depends on text never shown as it is
        // comes from the host (before the first edit, or while what was typed since does not decide it).
        let caseUnknown = slowBase.map { base in
            interruptContext != nil || !OracleRules.decides(String(decoding: fields[shown]!.units[min(base, fields[shown]!.caret) ..< fields[shown]!.caret], as: UTF16.self), mode: modes[shown]!)
        } ?? false
        let edit = typing.resolve(action, before: fields[shown]!.before, at: time)
        fields[shown]!.apply(deletes: edit.deletes, text: edit.text)
        if caseUnknown, case .character = action, edit.text.lowercased() != edit.text.uppercased() {
            let caret = fields[shown]!.caret, length = edit.text.utf16.count
            let host = harness.document.host.units
            if caret <= host.count, caret >= length {
                let typed = String(decoding: host[(caret - length) ..< caret], as: UTF16.self)
                if typed.lowercased() == edit.text.lowercased() {
                    fields[shown]!.units.replaceSubrange((caret - length) ..< caret, with: Array(typed.utf16))
                }
            }
        }
        if edit.deletes > 0 || !edit.text.isEmpty { interruptContext = nil }
        if let offset = unknown, edit.deletes > 0 { unknown = min(offset, fields[shown]!.caret) }
        if let base = slowBase, edit.deletes > 0 { slowBase = min(base, fields[shown]!.caret) }
        update()
    }

    /// The keyboard took another field (or none) as current: fingers held before any identity bind to
    /// it, those bound to another identified field end; the space and shift timing starts over.
    private func fieldChanged() {
        note("the keyboard takes \(name(current)) as current")
        keyboardField = current
        if let field = current {
            for (id, held) in bindings where !held.committed {
                if held.field == nil {
                    bindings[id]?.field = field
                } else if held.field != field {
                    bindings.removeValue(forKey: id)
                }
            }
            if let bound = deleteBinding, bound != field {
                deleteDone = true
            } else {
                deleteBinding = field
            }
        }
        typing.resetTiming()
        update()
    }

    /// A host callback that is not an echo of our own edits reached the keyboard.
    private func callbackDelivered() {
        if current != keyboardField {
            fieldChanged()
        } else {
            typing.resetTiming()
            update()
        }
    }

    /// Auto-capitalization from the text before the caret: the field's own text, except where no keyboard
    /// can know it (`unknown`), where it is what the keyboard can read.
    private func update() {
        if let context = interruptContext {
            typing.update(OracleRules.capitalizes(after: context, mode: modes[shown]!))
            return
        }
        if let offset = unknown, fields[shown]!.caret <= offset {
            typing.update(OracleRules.capitalizes(after: harness.document.contextBefore ?? "", mode: modes[shown]!))
        } else {
            typing.update(OracleRules.capitalizes(after: fields[shown]!.before, mode: modes[shown]!))
        }
    }

    // MARK: Gestures

    private func gestureStep() -> String? {
        guard quiet() else { return "the keyboard never settled before a gesture" }
        guard let field = current, field == keyboardField, fields[field]!.selection == 0 else { return nil }
        let oracleField = fields[field]!
        // The target: a column on this line or another, reached by one move over one-unit characters.
        let lines = lineStarts(oracleField.text)
        let line = lines.lastIndex { $0 <= oracleField.caret } ?? 0
        let column = graphemes(oracleField.text, from: lines[line], to: oracleField.caret)
        let targetLine = random.chance(0.5) ? line : min(max(line + random.below(5) - 2, 0), lines.count - 1)
        let length = graphemes(oracleField.text, from: lines[targetLine], to: lineEnd(oracleField.text, lines, targetLine))
        let targetColumn = targetLine == line ? random.below(length + 1) : min(column, length)
        let target = offset(oracleField.text, from: lines[targetLine], graphemes: targetColumn)
        let span = Array(oracleField.text.utf16)[min(target, oracleField.caret) ..< max(target, oracleField.caret)]
        let oneUnit = String(decoding: span, as: UTF16.self).allSatisfy { $0.utf16.count == 1 }
        // The snapshot drops a line break the context starts with, so a field's empty first line is
        // reached by a jump past its edge, which only the host's report places.
        let jumps = targetLine == 0 && oracleField.text.hasPrefix("\n")
        let predictable = wholeContext[field] == true && oneUnit && !jumps && random.chance(0.6)
        let dx = predictable ? Double(targetColumn - column) * 10 : Double(random.below(161) - 80)
        let dy = predictable ? Double(targetLine - line) * 20 : Double(random.below(81) - 40)
        // What happens around the lift: keys (at the lift of a predictable gesture; while a free one
        // settles, letters during probes included; Shift and layer keys among them, whose touch-down ends
        // the gesture too), an outside change, hiding, or nothing. Never a space: what follows a gesture
        // starts its space timing anew.
        enum Around { case nothing, keys(Int), outside, hide }
        // A slow host: its reports come after `syncTimeout`, outside the trackpad's guarantees (a probe
        // resolved by timeout may learn the wrong unit, so where a move lands is not known), or it shows our
        // edits late (after a key abandons a probe nothing shows the text before the insertion point until
        // the proxy catches up). Keys follow free gestures there too; only the case of a letter that depends
        // on text the keyboard cannot have read is taken from the host (`slowBase`).
        let reporting = harness.document.host
        let reportsInTime = reporting.callbackFrames.map {
            Double($0 + reporting.lagFrames) / 120 < TrackpadParameters.standard.syncTimeout
        } ?? true
        let slow = !predictable && (!reportsInTime || reporting.editContextLagFrames > 0)
        let around: Around
        switch random.below(10) {
        case 0 ..< 4: around = .keys(1 + random.below(4))
        case 4: around = predictable ? .nothing : .outside
        case 5: around = predictable ? .nothing : .hide
        default: around = .nothing
        }
        let outsideWhileHeld = random.chance(0.5)
        note("gesture \(predictable ? "to \(target)" : "free") dx \(dx) dy \(dy) \(around) in \(name(field)) caret \(oracleField.caret)"
            + (tracing ? " text \(oracleField.text.debugDescription)" : ""))
        inGesture = true
        defer { inGesture = false }
        // A key typed into an earlier gesture may have left the caret inside a cluster (the accepted
        // residual); a gesture that never moves does not repair that.
        let startedOnBoundary = harness.document.host.caretIsOnBoundary
        windowsSeen = harness.document.host.liveWindow.map { [$0] } ?? []
        let finger = harness.beginGesture()
        typing.resetTiming()
        let events = predictable ? 1 : 1 + random.below(4)
        for event in 0 ..< events {
            harness.drag(dx: dx / Double(events), dy: dy / Double(events))
            if case .outside = around, outsideWhileHeld, event == events / 2 { outsideChange(during: field) }
        }
        bindings.removeValue(forKey: finger)
        harness.touchUp(finger)
        if case .outside = around, !outsideWhileHeld {
            harness.frames(random.below(6))
            outsideChange(during: field)
        }
        if case .hide = around {
            harness.frames(random.below(6))
            hide()
            harness.frames(4 + random.below(30))
            show()
        }
        // Keys at the lift, or while it settles: picked as they are pressed, from the layer shown then.
        // Each edit is checked right after its release (`verify`).
        if case .keys(let count) = around {
            if predictable {
                // The move is in flight or landed: as far as keys are concerned, the caret is the target.
                fields[field]!.caret = target
                update()
            } else {
                harness.frames(random.below(8))
                placeAtInterruption(field)
                if slow { slowBase = fields[field]!.caret }
            }
            for _ in 0 ..< count {
                touchUp(touchDown(gestureKey(shift: !slow)))
            }
            unknown = nil
            interruptContext = nil
            slowBase = nil
            // Every report of the gesture a key ended arrives with no gesture running: a callback that is
            // not an echo, which starts the timing over (ARCHITECTURE.md, "Typing model v2").
            let deliveries = freeDeliveries
            guard quiet() else { return "the keyboard never settled after a gesture" }
            if freeDeliveries > deliveries { typing.resetTiming() }
            // The proxy now shows the field as it is, and the shift follows it (after an own edit it does
            // every frame, with no callback): from the field's own text again.
            update()
            if predictable, harness.document.host.caret != fields[field]!.caret {
                return "keys at the lift of a gesture to \(target) left the caret at \(harness.document.host.caret)"
            }
            return nil
        }
        guard quiet() else { return "the keyboard never settled after a gesture" }
        let host = harness.document.host
        // No key was typed since the gesture began, so its timing has only the shift's automatic decision
        // to start over, whatever the callbacks were.
        defer {
            typing.resetTiming()
            update()
        }
        if predictable {
            fields[field]!.caret = target
            if host.caret != target { return "a gesture to \(target) left the caret at \(host.caret)" }
            return nil
        }
        // No key interrupted it: the caret is the host's, on a character boundary, and only an outside
        // change changed the text. A host whose reports come after `syncTimeout` is outside the trackpad's
        // guarantees: a jump past the window's edge resolved by timeout, from a provisional answer that
        // shows the caret at that edge, may have stopped inside a hidden cluster.
        guard host.caretIsOnBoundary || !reportsInTime || !startedOnBoundary && host.caret == oracleField.caret else {
            return "a gesture left the caret inside a character at \(host.caret)"
        }
        guard host.units == fields[field]!.units else {
            return "a gesture changed the text: \(host.text.debugDescription) != \(fields[field]!.text.debugDescription)"
        }
        fields[field]!.caret = host.caret
        fields[field]!.selection = host.selectionLength
        return nil
    }

    /// A key typed around a gesture: a character or Return from the layer shown, delete, Shift (unless
    /// `shift` is false: on a slow host what it leaves the shift at may depend on text never shown), or a
    /// layer key.
    private func gestureKey(shift: Bool = true) -> KeyAction {
        switch random.below(10) {
        case 0, 1: return .delete
        case 2:
            let switches = keys { action in
                if case .layer = action { return true }
                return shift && action == .shift
            }
            return switches.isEmpty ? .delete : random.pick(switches)
        default: return random.pick(typedKeys(space: false))
        }
    }

    /// The first key after a free gesture's lift ends it at its touch-down (ARCHITECTURE.md, "Typing
    /// model v2"). Only where the keys act comes from the host: the caret once what the gesture already
    /// issued has landed (observed on a copy, so nothing lands early). The shift follows the text the
    /// keyboard can read there, derived here without asking it: with the gesture's last move landing on a
    /// boundary, the field's own text before that caret within the window the proxy showed as it is around
    /// it (`windowsSeen`); with a probe or a jump out whose outcome is abandoned (or the gesture already
    /// over), the proxy's context. Every key from here on is checked exactly, case included (`unknown` and
    /// `slowBase` state the limits). Only whether the keyboard has a landing at all is read from it.
    private func placeAtInterruption(_ field: UUID) {
        let session = harness.trackpad.session
        let caret = harness.document.host.caretOnceAdjusted
        fields[field]!.caret = caret
        typing.resetTiming()
        if session?.landingBefore != nil {
            // The window the proxy showed around the caret: the first one (the gesture's snapshot) if it
            // covers it, else the latest that does. None does: the field's own text decides the first key,
            // and the proxy what follows once deletions reach before the caret.
            let window = windowsSeen.first.flatMap { $0.contains(caret) || $0.upperBound == caret ? $0 : nil }
                ?? windowsSeen.last { $0.contains(caret) || $0.upperBound == caret }
            unknown = window?.lowerBound ?? caret
            interruptContext = String(decoding: fields[field]!.units[(window?.lowerBound ?? 0) ..< caret], as: UTF16.self)
        } else {
            // A probe or a jump abandoned: the proxy's reading. Only a key that ends a running gesture
            // abandons an outcome; one that settled left the proxy showing where it put the caret.
            unknown = session != nil ? caret : nil
            interruptContext = harness.document.contextBefore ?? ""
        }
        typing.update(OracleRules.capitalizes(after: interruptContext!, mode: modes[field]!))
        note("placed at \(caret), shift from the \(session?.landingBefore != nil ? "landing" : "proxy")")
    }

    private func lineStarts(_ text: String) -> [Int] {
        var starts = [0], offset = 0
        for character in text {
            offset += character.utf16.count
            if character.isNewline { starts.append(offset) }
        }
        return starts
    }

    private func lineEnd(_ text: String, _ starts: [Int], _ line: Int) -> Int {
        line + 1 < starts.count ? starts[line + 1] - 1 : text.utf16.count
    }

    private func graphemes(_ text: String, from start: Int, to end: Int) -> Int {
        let units = Array(text.utf16)
        return String(decoding: units[start ..< max(start, end)], as: UTF16.self).count
    }

    private func offset(_ text: String, from start: Int, graphemes count: Int) -> Int {
        let units = Array(text.utf16)
        let rest = String(decoding: units[start...], as: UTF16.self)
        return start + rest.prefix(count).utf16.count
    }

    // MARK: The host app

    /// The host app's own edit or caret move while a gesture runs: the text changes as the host says,
    /// and the caret is the host's.
    private func outsideChange(during field: UUID) {
        var oracleField = fields[field]!
        let boundaries = oracleField.boundaries
        switch random.below(3) {
        case 0:
            let at = random.pick(boundaries)
            let inserted = random.pick(["zz", "Hi. ", "\n", "\u{1F44D}", "e\u{301}"])
            harness.document.hostInserts(inserted, at: at, reportAfter: 1 + random.below(3))
            oracleField.units.insert(contentsOf: Array(inserted.utf16), at: at)
        case 1:
            guard boundaries.count > 2 else { return }
            let first = random.below(boundaries.count - 1)
            let range = boundaries[first] ..< boundaries[min(first + 1 + random.below(3), boundaries.count - 1)]
            harness.document.hostDeletes(range, reportAfter: 1 + random.below(3))
            oracleField.units.removeSubrange(range)
        default:
            harness.document.moveCaret(to: random.pick(boundaries), reportedAsTextChange: random.chance(0.5))
        }
        fields[field] = oracleField
        note("outside change in \(name(field)) during a gesture")
    }

    private func hostEditStep() -> String? {
        guard quiet() else { return "the keyboard never settled before the host's edit" }
        guard let field = current, field == keyboardField else { return nil }
        // Long enough after the last key that its own edit's state can no longer be matched: a host edit
        // away from the caret can look just like one.
        let echoesEnd = lastKeyAt + EditingCore.ownEditLifetime + 0.05
        for _ in 0 ..< 200 where time <= echoesEnd { harness.frame() }
        var oracleField = fields[field]!
        let boundaries = oracleField.boundaries
        let turns = 1 + random.below(3)
        switch random.below(4) {
        case 0:
            let at = random.pick(boundaries)
            let inserted = random.pick(["zz", "Hi. ", "\n", "\u{1F44D}", "e\u{301}"])
            harness.document.hostInserts(inserted, at: at, reportAfter: turns)
            if at <= oracleField.caret { oracleField.caret += inserted.utf16.count }
            oracleField.units.insert(contentsOf: Array(inserted.utf16), at: at)
        case 1:
            guard boundaries.count > 2 else { return nil }
            let first = random.below(boundaries.count - 1)
            let range = boundaries[first] ..< boundaries[min(first + 1 + random.below(3), boundaries.count - 1)]
            harness.document.hostDeletes(range, reportAfter: turns)
            oracleField.units.removeSubrange(range)
            if oracleField.caret >= range.upperBound {
                oracleField.caret -= range.count
            } else if oracleField.caret > range.lowerBound {
                oracleField.caret = range.lowerBound
            }
            oracleField.selection = 0
        case 2:
            let to = random.pick(boundaries)
            harness.document.moveCaret(to: to, reportedAsTextChange: random.chance(0.5))
            oracleField.caret = to
            oracleField.selection = 0
        default:
            let first = random.below(boundaries.count)
            let last = min(first + random.below(4), boundaries.count - 1)
            harness.document.select(from: boundaries[first], length: boundaries[last] - boundaries[first])
            oracleField.caret = boundaries[first]
            oracleField.selection = boundaries[last] - boundaries[first]
        }
        fields[field] = oracleField
        note("host edit in \(name(field)): caret \(oracleField.caret)+\(oracleField.selection) text \(oracleField.text.debugDescription)")
        guard deliverCallbacks() else { return "the host's callback never arrived" }
        return nil
    }

    /// Frames until the host's scheduled callbacks have reached the keyboard; then the oracle applies
    /// what a callback that is not an echo does.
    private func deliverCallbacks() -> Bool {
        for _ in 0 ..< 20 where harness.document.pendingCallbacks > 0 { harness.frame() }
        guard harness.document.pendingCallbacks == 0 else { return false }
        callbackDelivered()
        return true
    }

    // MARK: Focus and identity

    private func name(_ id: UUID?) -> String {
        guard let id else { return "-" }
        return id == ids[0] ? "A" : "B"
    }

    private func otherField() -> UUID {
        shown == ids[0] ? ids[1] : ids[0]
    }

    private func switchShown(to field: UUID, identified: Bool) {
        parked[shown] = harness.document.host
        harness.document.switchField(to: parked.removeValue(forKey: field)!, id: identified ? field : nil)
        shown = field
        current = identified ? field : nil
        harness.autocapitalization = modes[field]!
    }

    private func focusStep() -> String? {
        guard quiet() else { return "the keyboard never settled before a focus change" }
        guard current != nil else { return nil }
        let to = otherField()
        note("focus to \(name(to))")
        // Sometimes a finger was already down in the old field, one touches down in the new field before
        // its first callback, and a key is typed there before that callback.
        let early = random.chance(0.4) ? touchDown(random.pick(typedKeys())) : nil
        switchShown(to: to, identified: true)
        let late = random.chance(0.5) ? touchDown(random.pick(typedKeys())) : nil
        // (No space: the callback after it shows what that key left, which is taken for its echo.)
        if random.chance(0.4) { touchUp(touchDown(random.pick(typedKeys(space: false)))) }
        if let early, random.chance(0.5) { touchUp(early) }
        harness.document.report(after: 1 + random.below(3))
        guard deliverCallbacks() else { return "the focus change's callback never arrived" }
        if let early { touchUp(early) }
        if let late { touchUp(late) }
        return nil
    }

    private func unidentifiedStep() -> String? {
        guard quiet() else { return "the keyboard never settled before a transition" }
        let comesBackTo = random.chance(0.5) ? shown : otherField()
        note("unidentified, then \(name(comesBackTo))")
        if comesBackTo != shown {
            switchShown(to: comesBackTo, identified: false)
        } else {
            harness.document.documentID = nil
            current = nil
        }
        // Sometimes a finger touched down while nothing is identified stays down through what follows.
        let held = random.chance(0.4) ? touchDown(random.pick(typedKeys())) : nil
        harness.document.report(after: 1)
        guard deliverCallbacks() else { return "the transition's callback never arrived" }
        // Keys while nothing is identified go to the field the proxy shows, at once.
        for _ in 0 ..< random.below(4) {
            touchUp(touchDown(random.pick(typedKeys())))
            harness.frames(random.below(3))
        }
        harness.document.documentID = comesBackTo
        current = comesBackTo
        harness.document.report(after: 1)
        guard deliverCallbacks() else { return "the identity's callback never arrived" }
        // The held finger is bound to that field now: on to the other field, it ends without typing.
        if held != nil, random.chance(0.5) {
            switchShown(to: otherField(), identified: true)
            harness.document.report(after: 1)
            guard deliverCallbacks() else { return "the focus change's callback never arrived" }
        }
        if let held { touchUp(held) }
        return nil
    }

    // MARK: Hiding

    /// Hidden for at least a few frames (an appearance takes far longer), by when the proxy shows our last
    /// edits: the keyboard reappears reading the field as it is.
    private func hideStep() -> String? {
        note("hide")
        // A finger may be down: hiding ends it without typing. Everything typed before is in the field.
        let held = random.chance(0.4) ? touchDown(random.pick(typedKeys())) : nil
        hide()
        if let held { harness.touchUp(held) }
        harness.frames(4 + random.below(30))
        show()
        return nil
    }

    private func hide() {
        harness.hide()
        bindings.removeAll()
        deleteDone = true
        note("hidden")
    }

    /// The keyboard appears again in the field it serves: letters, and the timing starts over.
    private func show() {
        harness.show()
        keyboardField = current
        typing.layer = .letters
        typing.resetTiming()
        update()
        note("shown")
    }

    // MARK: Checks

    /// The documents, the caret and the selection, and the keyboard's shift and layer, once settled.
    func check() -> String? {
        for id in ids {
            let host = id == shown ? harness.document.host : parked[id]!
            let expected = fields[id]!
            if host.units != expected.units {
                return "field \(name(id)): \(host.text.debugDescription) != expected \(expected.text.debugDescription)"
            }
            if id == shown, host.caret != expected.caret || host.selectionLength != expected.selection {
                return "field \(name(id)): caret \(host.caret)+\(host.selectionLength) != expected \(expected.caret)+\(expected.selection)"
            }
        }
        if typing.shift != harness.editor.typing.shift || typing.layer != harness.editor.typing.layer {
            let field = fields[shown]!
            return "keyboard state \(harness.editor.typing.shift)/\(harness.editor.typing.layer) != expected \(typing.shift)/\(typing.layer)"
                + " (\(modes[shown]!); before \(String(field.before.suffix(12)).debugDescription), the editor read "
                + "\(String((harness.editor.currentBefore ?? "").suffix(12)).debugDescription))"
        }
        return nil
    }
}
