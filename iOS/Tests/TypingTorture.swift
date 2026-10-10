import Foundation

/// The typing torture test (round 8, ARCHITECTURE.md, "Typing correctness is paramount"): a seeded
/// script of touches (taps, holds, rollover; shift, caps lock, layers; space, double space, return,
/// delete), trackpad gestures (with keys at the lift), focus changes between two fields, fields without
/// an identity, the host app's own edits, caret moves and selections, against hosts with lagging
/// adjustments, long or missing callbacks, WebKit's double reports and proxy contexts that lag the
/// keyboard's own edits.
///
/// The oracle computes the expected documents, carets and selections from the script alone, by the
/// contract: a key acts at its press (or release) with the shift and layer of that moment, in the field
/// it was pressed in once that field is identified, in press order; a gesture whose target the script
/// knows (a whole-context field, a span of one-unit characters) lands exactly there. Only where the
/// contract leaves the caret to the host (a gesture that needs probes, or ends early) does the oracle
/// take the host's caret, after checking it is on a character boundary and that keys typed then are all
/// there, in order, contiguous, at that caret, and nothing else changed. Deterministic per seed.
struct TypingTorture {
    struct Failure: Equatable {
        var step: Int
        var message: String
    }

    let seed: UInt64

    /// Runs `steps` steps of the seed's script, checking after every step that leaves the keyboard
    /// quiet; nil if everything matched.
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

/// The keyboard's typing state as the contract describes it (TypingRules), kept by the oracle.
private struct OracleTyping {
    var layer = KeyboardLayer.letters
    var shift = ShiftMode.off
    var automatic = false
    var lastShiftTap: TimeInterval?
    var lastSpace: TimeInterval?
    var decision: Bool?

    mutating func tapShift(at time: TimeInterval) {
        if let last = lastShiftTap, time >= last, time - last <= TypingParameters.standard.shiftDoubleTapInterval {
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
            if let last = lastSpace, time >= last, time - last <= TypingParameters.standard.doubleSpaceInterval,
               DoubleSpacePeriod.applies(before: before) {
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

    mutating func update(_ shouldCapitalize: Bool) {
        guard shouldCapitalize != decision else { return }
        decision = shouldCapitalize
        if shouldCapitalize, shift == .off {
            shift = .once
            automatic = true
        } else if !shouldCapitalize, shift == .once, automatic {
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

/// A field as the oracle expects it.
private struct OracleField {
    var text: String
    var caret: Int
    var selection = 0

    var before: String {
        String(decoding: Array(text.utf16)[..<caret], as: UTF16.self)
    }

    /// UTF-16 offsets of every character boundary.
    var boundaries: [Int] {
        var offsets = [0], offset = 0
        for character in text {
            offset += character.utf16.count
            offsets.append(offset)
        }
        return offsets
    }

    /// The host's own semantics: delete the selection, or the character before the caret; insert in
    /// place of the selection.
    mutating func apply(deletes: Int, text inserted: String) {
        for _ in 0 ..< deletes {
            var units = Array(text.utf16)
            if selection > 0 {
                units.removeSubrange(caret ..< caret + selection)
                selection = 0
            } else {
                guard caret > 0 else { continue }
                let start = boundaries.last { $0 < caret } ?? 0
                units.removeSubrange(start ..< caret)
                caret = start
            }
            text = String(decoding: units, as: UTF16.self)
        }
        guard !inserted.isEmpty else { return }
        var units = Array(text.utf16)
        units.replaceSubrange(caret ..< caret + selection, with: Array(inserted.utf16))
        text = String(decoding: units, as: UTF16.self)
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
    /// The identified field the proxy serves, nil during a transition; and the field it shows.
    private var current: UUID?
    private var shown: UUID
    /// Keys submitted while no field was identified, resolved then.
    private var waiting: [(deletes: Int, text: String, field: UUID?, at: TimeInterval)] = []
    private var lastKey: KeyAction?
    /// What the script did lately, for a failure's message.
    private var log: [String] = []
    /// `TORTURE_TRACE=1`: every event also shows the keyboard's and the oracle's view, and every frame
    /// of a gesture the host's (invented text only), for debugging a failing seed.
    private let tracing = ProcessInfo.processInfo.environment["TORTURE_TRACE"] != nil
    private var inGesture = false
    private var logLimit: Int { tracing ? 2_000 : 40 }

    private func note(_ event: String) {
        var line = String(format: "%.3f ", time - 100) + event
        if tracing {
            line += " [keyboard \(harness.editor.typing.shift) reads \(String((harness.editor.currentBefore ?? "").suffix(8)).debugDescription)"
                + ", oracle \(typing.shift) \(String(fields[shown]!.before.suffix(8)).debugDescription), waiting \(harness.editor.isWaiting)]"
        }
        log.append(line)
        if log.count > logLimit { log.removeFirst(log.count - logLimit) }
    }

    var recentEvents: String { log.suffix(tracing ? 2_000 : 24).joined(separator: "\n  ") }
    private var lastKeyAt: TimeInterval = -.infinity

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
            // Reports up to 30 frames late (with lag and a second report, within `syncTimeout`, the trackpad's
            // contract); later ones are a residual covered by focused tests only (a key waits for them).
            let callbackFrames = random.pick([nil, 1, 2, 3, 20, 30] as [Int?])
            // A proxy answers provisionally until the host's report replaces it, so a lagging host needs
            // reports and a provisional answer; a host that never reports never leaves one stale.
            let lag = callbackFrames == nil ? 0 : random.below(4)
            let provisional = callbackFrames != nil && (lag > 0 || random.chance(0.5))
            var host = FakeTextHost(text: texts[index], unit: unit, model: model, lagFrames: lag,
                                    callbackFrames: callbackFrames, provisionalContext: provisional)
            let doubleReports = unit == .grapheme && callbackFrames != nil && random.chance(0.5)
            host.reportsAsIssuedFirst = doubleReports
            // A host that shows the keyboard's edits late shows text past a line break (a residual: where
            // the proxy shows only the break at a line start, a key typed within that lag after deleting
            // the break cannot know the text before it, and is cased by the stale break).
            let lagsEdits = random.chance(0.25) && model != .lineBreakOnly
            host.editContextLagFrames = lagsEdits ? 1 + random.below(3) : 0
            hosts.append(host)
            modes[id] = random.pick([AutocapitalizationMode.sentences, .sentences, .none, .words, .allCharacters])
            wholeContext[id] = model == .whole
            fields[id] = OracleField(text: host.text, caret: host.caret)
        }
        self.random = random
        self.ids = ids
        self.modes = modes
        self.wholeContext = wholeContext
        self.fields = fields
        parked = [ids[1]: hosts[1]]
        current = ids[0]
        shown = ids[0]
        harness = KeyboardHarness(hosts[0], autocapitalization: modes[ids[0]]!, documentID: ids[0])
        update()
        if tracing {
            harness.onFrame = { [unowned self] in
                guard self.inGesture else { return }
                let host = self.harness.document.host
                self.note("frame: trackpad \(self.harness.trackpad.isActive ? "on" : "off"), caret \(host.caret), proxy "
                    + "\(String((self.harness.document.contextBefore ?? "").suffix(8)).debugDescription), \(host.traceDescription), "
                    + "outcomes \(self.harness.outcomes.suffix(2)), unit learned \(self.harness.trackpad.learnedUnit(for: self.harness.document.documentID).map { "\($0)" } ?? "-")")
            }
        }
    }

    private var time: TimeInterval { harness.time }

    // MARK: Steps

    /// One step of the script; a message if the keyboard and the oracle disagree.
    func step() -> String? {
        let roll = random.below(100)
        switch roll {
        case 0 ..< 45: keyStep()
        case 45 ..< 55: harness.frames(1 + random.below(4))
        case 55 ..< 70: if let message = gestureStep() { return message }
        case 70 ..< 78: if quiet() { hostEditStep() }
        case 78 ..< 86: if quiet() { focusStep() }
        case 86 ..< 91: if quiet() { unidentifiedStep() }
        case 91 ..< 96: deleteHoldStep()
        default: shiftOrLayerStep()
        }
        return check()
    }

    /// Lets everything settle, then compares.
    func finish() -> String? {
        _ = quiet(maxFrames: 2_400)
        return check()
    }

    /// Frames until the keyboard is quiet (no session, no waiting keys, no callbacks to come, no late
    /// reports owed). False if it never got there.
    @discardableResult
    private func quiet(maxFrames: Int = 1_200) -> Bool {
        for _ in 0 ..< maxFrames {
            if harness.isQuiet, !harness.trackpad.owesReports(at: time) { return true }
            harness.frame()
        }
        return harness.isQuiet
    }

    // MARK: Keys

    private func keys(_ filter: (KeyAction) -> Bool) -> [KeyAction] {
        harness.model.keys.map(\.action).filter(filter)
    }

    private func typedKeys() -> [KeyAction] {
        keys { action in
            switch action {
            case .character, .space, .returnKey: return true
            default: return false
            }
        }
    }

    private func keyStep() {
        var action = random.chance(0.12) ? KeyAction.space : random.pick(typedKeys())
        // Two spaces in a row are kept (". "), but not three.
        if action == .space, lastKey == .space, random.chance(0.5) { action = random.pick(typedKeys()) }
        switch random.below(10) {
        case 0:
            // Rollover: a second finger lands while the first is down, then both lift.
            let second = random.pick(typedKeys())
            let first = touchDown(action)
            let next = touchDown(second)
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
    }

    private func shiftOrLayerStep() {
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
    }

    private func deleteHoldStep() {
        note("delete hold")
        let id = touchDown(.delete)
        // Released before the first deletion (0.12 s), or after it and before the first repeat (0.6 s).
        let frames = random.chance(0.5) ? random.below(10) : 20 + random.below(30)
        for frame in 0 ..< frames {
            harness.frame()
            // The first deletion fires on the frame at or after 0.12 s.
            if frame + 1 == Int((DeleteRepeatParameters.standard.firstDeletionDelay * 120).rounded(.up)) {
                deleteFired(binding: deleteBinding, at: time)
            }
        }
        touchUp(id)
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
    private var deleteFiredOnce = false
    /// The layer the key area's keys were last laid out for.
    private var layoutLayer = KeyboardLayer.letters

    private func touchDown(_ action: KeyAction) -> KeyTouchModel.TouchID {
        guard let point = harness.center(action) else { preconditionFailure("the script pressed \(action), not shown") }
        // A new finger commits every earlier one still held: characters, space and return.
        for (id, held) in bindings.sorted(by: { $0.key < $1.key }) where !held.committed {
            switch (held.role, held.action) {
            case (.character, .character?), (.space, .space?), (.returnKey, .returnKey?):
                bindings[id]?.committed = true
                submit(held.action!, binding: held.field)
            default:
                break
            }
        }
        let id = harness.touchDown(action)
        let role: Role
        switch action {
        case .character: role = .character
        case .space: role = .space
        case .returnKey: role = .returnKey
        default: role = .other
        }
        bindings[id] = Held(action: action, role: role, field: harness.field, x: point.x, y: point.y)
        switch action {
        case .shift:
            typing.tapShift(at: time)
        case .layer(let layer):
            typing.switchLayer(layer)
            update()
        case .delete:
            deleteBinding = harness.field
            deleteFiredOnce = false
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
            submit(held.action!, binding: held.field)
        case (.other, .delete?):
            // A release before the first deletion deletes once, unless another identified field is current.
            guard !deleteFiredOnce else { break }
            if let bound = deleteBinding, let field = current, bound != field { break }
            deleteFiredOnce = true
            submit(.delete, binding: deleteBinding ?? current)
        default:
            break
        }
        remapHeldKeys()
    }

    private func deleteFired(binding: UUID?, at time: TimeInterval) {
        guard bindings.values.contains(where: { $0.action == .delete }) else { return }
        if let bound = binding, let field = current, bound != field { return }
        deleteFiredOnce = true
        if deleteBinding == nil { deleteBinding = current }
        submit(.delete, binding: deleteBinding)
    }

    /// A key reaches the editor (`KeyboardEditor.submit`): pressed in another identified field, it never
    /// runs; with no field identified, it waits; otherwise it acts now.
    private func submit(_ action: KeyAction, binding: UUID?) {
        lastKey = action
        lastKeyAt = time
        note("key \(action) bound \(name(binding)) in \(name(current)) shift \(typing.shift) (keyboard: \(harness.editor.typing.shift)) layer \(typing.layer)")
        if let bound = binding, let field = current, bound != field { return }
        let target = current ?? shown
        var field = fields[target]!
        for key in waiting { field.apply(deletes: key.deletes, text: key.text) }
        let edit = typing.resolve(action, before: field.before, at: time)
        if current == nil {
            waiting.append((edit.deletes, edit.text, binding, time))
            field.apply(deletes: edit.deletes, text: edit.text)
            update(before: field.before, mode: modes[target]!)
        } else {
            fields[target]!.apply(deletes: edit.deletes, text: edit.text)
            update()
        }
    }

    private func update() {
        let field = current ?? shown
        update(before: fields[field]!.before, mode: modes[field]!)
    }

    private func update(before: String, mode: AutocapitalizationMode) {
        typing.update(AutoCapitalization.shouldCapitalize(before: before, mode: mode))
    }

    // MARK: Gestures

    private func gestureStep() -> String? {
        guard quiet(), let field = current, fields[field]!.selection == 0 else { return nil }
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
        // The snapshot drops a line break the context starts with, so a field's empty first line is reached
        // by a jump past its edge, which keys at the lift wait for, cased as the keyboard shows them then.
        let jumps = targetLine == 0 && oracleField.text.hasPrefix("\n")
        let predictable = wholeContext[field] == true && oneUnit && !jumps && random.chance(0.7)
        let dx = predictable ? Double(targetColumn - column) * 10 : Double(random.below(161) - 80)
        let dy = predictable ? Double(targetLine - line) * 20 : Double(random.below(81) - 40)
        // A gesture that needs probes: keys typed at the lift are digits and deletes, whose case cannot
        // depend on where the host left the caret.
        var burst: [KeyAction] = []
        if !predictable, random.chance(0.5) {
            if typing.layer != .numbers, let key = keys({ $0 == .layer(.numbers) }).first { touchUp(touchDown(key)) }
            let digits = keys { if case .character(let c) = $0 { return c.first?.isNumber == true } else { return false } }
            if !digits.isEmpty {
                for _ in 0 ..< 1 + random.below(4) { burst.append(random.chance(0.25) ? .delete : random.pick(digits)) }
            }
        }
        // Keys typed at the lift are picked as they are pressed, from the layer shown then.
        let atLift = predictable && random.chance(0.5) ? 1 + random.below(3) : 0
        note("gesture \(predictable ? "to \(target)" : "free") dx \(dx) dy \(dy) burst \(burst) atLift \(atLift) in \(name(field)) caret \(oracleField.caret)"
            + (tracing ? " text \(oracleField.text.debugDescription)" : ""))
        inGesture = true
        defer { inGesture = false }
        let finger = harness.beginGesture()
        typing.resetTiming()
        let events = predictable ? 1 : 1 + random.below(4)
        for _ in 0 ..< events { harness.drag(dx: dx / Double(events), dy: dy / Double(events)) }
        bindings.removeValue(forKey: finger)
        harness.touchUp(finger)
        if predictable {
            // The move is in flight or landed: the caret is the target, as far as keys are concerned.
            fields[field]!.caret = target
            update()
            for _ in 0 ..< atLift { touchUp(touchDown(random.pick(typedKeys()))) }
            guard quiet() else { return "the keyboard never settled after a gesture" }
            if harness.document.host.caret != fields[field]!.caret {
                return "a gesture to \(target) left the caret at \(harness.document.host.caret)"
            }
            return nil
        }
        // Where the host left the caret is the host's; what was typed there must be all there.
        var burstEdits: [(deletes: Int, text: String)] = []
        for key in burst {
            // Straight to the key area (a delete tap deletes once, at its release).
            burstEdits.append(typing.resolve(key, before: "", at: time))
            lastKey = key
            lastKeyAt = time
            note("burst key \(key)")
            harness.tap(key)
        }
        guard quiet() else { return "the keyboard never settled after a gesture" }
        let host = harness.document.host
        guard host.caretIsOnBoundary else { return "a gesture left the caret inside a character at \(host.caret)" }
        var matched: OracleField?
        for start in oracleField.boundaries {
            var candidate = oracleField
            candidate.caret = start
            for edit in burstEdits { candidate.apply(deletes: edit.deletes, text: edit.text) }
            if candidate.text == host.text, candidate.caret == host.caret {
                matched = candidate
                break
            }
        }
        guard let matched else {
            return "keys typed at a gesture's lift were not all there, in order, at one caret: "
                + "\(host.text.debugDescription) from \(oracleField.text.debugDescription) with \(burstEdits)"
        }
        fields[field] = matched
        update()
        note("gesture landed at \(matched.caret)")
        return nil
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

    private func hostEditStep() {
        guard let field = current else { return }
        // Long enough after the last key ran (at most `maximumWait` after its press) that no report could
        // still be taken for one of our own edits: a host edit away from the caret can look just like one.
        let reportsOfKeysEnd = lastKeyAt + KeyboardEditor.maximumWait + EditingCore.ownEditLifetime + 0.05
        for _ in 0 ..< 400 where time <= reportsOfKeysEnd { harness.frame() }
        var oracleField = fields[field]!
        let boundaries = oracleField.boundaries
        let turns = 1 + random.below(3)
        switch random.below(4) {
        case 0:
            let at = random.pick(boundaries)
            let inserted = random.pick(["zz", "Hi. ", "\n", "\u{1F44D}", "e\u{301}"])
            harness.document.hostInserts(inserted, at: at, reportAfter: turns)
            if at <= oracleField.caret { oracleField.caret += inserted.utf16.count }
            var units = Array(oracleField.text.utf16)
            units.insert(contentsOf: Array(inserted.utf16), at: at)
            oracleField.text = String(decoding: units, as: UTF16.self)
        case 1:
            guard boundaries.count > 2 else { return }
            let first = random.below(boundaries.count - 1)
            let range = boundaries[first] ..< boundaries[min(first + 1 + random.below(3), boundaries.count - 1)]
            harness.document.hostDeletes(range, reportAfter: turns)
            var units = Array(oracleField.text.utf16)
            units.removeSubrange(range)
            oracleField.text = String(decoding: units, as: UTF16.self)
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
        // Reported later; then the field changed under the keyboard.
        quiet()
        typing.resetTiming()
        update()
    }

    // MARK: Focus

    private func name(_ id: UUID?) -> String {
        guard let id else { return "-" }
        return id == ids[0] ? "A" : "B"
    }

    private func otherField() -> UUID {
        current == ids[0] ? ids[1] : ids[0]
    }

    private func switchShown(to field: UUID, identified: Bool) {
        parked[shown] = harness.document.host
        harness.document.switchField(to: parked.removeValue(forKey: field)!, id: identified ? field : nil)
        shown = field
        harness.autocapitalization = modes[field]!
    }

    private func focusStep() {
        let to = otherField()
        note("focus to \(name(to))")
        // Sometimes a finger was already down in the old field, and one touches down in the new field
        // before its first callback.
        let early = random.chance(0.4) ? touchDown(random.pick(typedKeys())) : nil
        switchShown(to: to, identified: true)
        current = to
        let late = random.chance(0.5) ? touchDown(random.pick(typedKeys())) : nil
        harness.document.report(after: 1 + random.below(3))
        // The callback: another field. Fingers bound to the old one end without typing.
        for _ in 0 ..< 10 where harness.document.pendingCallbacks > 0 { harness.frame() }
        typing.resetTiming()
        update()
        if let early {
            // Cancelled by the focus change (or, released after it, refused): never typed.
            bindings.removeValue(forKey: early)
            harness.touchUp(early)
        }
        if let late { touchUp(late) }
        quiet()
    }

    private func unidentifiedStep() {
        let comesBackTo = random.chance(0.5) ? current! : otherField()
        note("unidentified, then \(name(comesBackTo))")
        if comesBackTo != current { switchShown(to: comesBackTo, identified: false) } else { harness.document.documentID = nil }
        current = nil
        harness.document.report(after: 1)
        harness.frame()
        typing.resetTiming()
        update()
        let short = random.chance(0.6)
        let total = short ? 4 + random.below(14) : 80 + random.below(30)
        for frame in 0 ..< total {
            // Keys while nothing is identified: early in a long transition (they run out of time), or any
            // time in a short one.
            if (short || frame < 6), random.chance(0.3) { touchUp(touchDown(random.pick(typedKeys()))) }
            harness.frame()
        }
        harness.document.documentID = comesBackTo
        current = comesBackTo
        // The waiting keys run in the field now identified, if they were pressed there (or before any
        // identity) and their time is not up.
        var field = fields[comesBackTo]!
        for key in waiting where time - key.at <= KeyboardEditor.maximumWait && (key.field == nil || key.field == comesBackTo) {
            field.apply(deletes: key.deletes, text: key.text)
        }
        fields[comesBackTo] = field
        waiting = []
        harness.document.report(after: 1)
        quiet()
        typing.resetTiming()
        update()
    }

    // MARK: Checks

    /// The documents, the caret and the selection, once the keyboard is quiet.
    func check() -> String? {
        guard harness.isQuiet, !harness.trackpad.owesReports(at: time), current != nil else { return nil }
        for id in ids {
            let host = id == shown ? harness.document.host : parked[id]!
            let expected = fields[id]!
            if host.text != expected.text {
                return "field \(id == ids[0] ? "A" : "B"): \(host.text.debugDescription) != expected \(expected.text.debugDescription)"
            }
            if id == shown, host.caret != expected.caret || host.selectionLength != expected.selection {
                return "field \(id == ids[0] ? "A" : "B"): caret \(host.caret)+\(host.selectionLength) != expected \(expected.caret)+\(expected.selection)"
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
