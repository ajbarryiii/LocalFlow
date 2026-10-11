import Foundation

/// Lays text out in columns: `columns` graphemes per line (wrapping anywhere), line breaks end
/// lines, and every grapheme is `width` points wide unless `advance` says otherwise.
struct FixedWidthLayout: LineLayout {
    var columns: Int
    var width: Double = 10
    var advance: ((String) -> Double)?

    func lines(in text: String) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start = 0, offset = 0, count = 0
        for character in text {
            offset += character.utf16.count
            if character.isNewline {
                lines.append(start ..< offset)
                start = offset
                count = 0
                continue
            }
            count += 1
            if count == columns {
                lines.append(start ..< offset)
                start = offset
                count = 0
            }
        }
        if start < offset || lines.isEmpty || text.last?.isNewline == true { lines.append(start ..< offset) }
        return lines
    }

    func x(atUTF16 offset: Int, line: Range<Int>, in text: String) -> Double {
        var position = 0, x = 0.0
        for character in text {
            if position >= offset { break }
            if position >= line.lowerBound { x += advance?(String(character)) ?? width }
            position += character.utf16.count
        }
        return x
    }
}

/// Advances for tests: "m" is wide, "i" narrow, everything else 10 points.
func testAdvance(_ grapheme: String) -> Double {
    switch grapheme {
    case "m": return 16
    case "i": return 5
    default: return 10
    }
}

/// What the proxy shows around the caret.
enum FakeContextModel {
    /// The whole document.
    case whole
    /// As measured in UIKit (iOS 26.4 simulator, a UITextView, 2026-10-09): before the caret, from the
    /// start of the sentence two before the one the caret ends (spanning line breaks); after it, to
    /// the end of the caret's sentence or the next line break, whichever comes first.
    case uikit
    /// An earlier reading, kept for the original undo regression: right after a line break only "\n"
    /// shows before the caret, further into a line the text after the break; after it, up to the
    /// next line break.
    case lineBreakOnly
}

/// A host document as a keyboard sees it through the proxy, with the behavior measured in the
/// simulator: `adjustTextPosition` counts UTF-16 code units (UIKit) or grapheme clusters (WebKit),
/// an offset past either end is ignored, the context window can be limited, and adjustments can
/// land a few frames late. `insertText` and `deleteBackward` change the text at once and send no
/// callback; an adjustment sends `textDidChange` after it lands.
struct FakeTextHost {
    /// The document as UTF-16 code units, as UIKit's NSString storage keeps it: a key inserted between the
    /// halves of a surrogate pair leaves both halves intact, and deleting it rejoins them.
    private(set) var units: [UInt16]
    /// The document as a Swift string: a lone surrogate half reads as U+FFFD (one unit, so offsets agree).
    var text: String {
        get { String(decoding: units, as: UTF16.self) }
        set { units = Array(newValue.utf16) }
    }
    /// The caret as a UTF-16 offset.
    private(set) var caret: Int
    var unit: CursorOffsetUnit
    var model: FakeContextModel
    /// Graphemes shown at most on each side of the caret; nil: as the model says.
    var window: Int?
    var lagFrames: Int
    /// `textDidChange` arrives this many frames after each adjustment lands, even an ignored one (the
    /// proxy shows the caret unmoved afterwards, as measured); nil sends none.
    var callbackFrames: Int?
    /// As measured in UIKit: until that callback the proxy answers from the context it last reported,
    /// the caret moved by the offset in code units and clamped to that text.
    var provisionalContext: Bool
    /// As measured in a WKWebView (round 6): every adjustment is reported twice, first with the context
    /// it was issued in, a frame later as it landed; each report shows the caret as of that adjustment,
    /// in order, and the proxy keeps showing it until the next report.
    var reportsAsIssuedFirst = false
    private var queued: [(offset: Int, frames: Int)] = []
    /// Callbacks still to come: in how many frames, and (WebKit) the caret the report shows.
    private var callbacks: [(frames: Int, shows: Int?)] = []
    private var provisional: (units: [UInt16], caret: Int)?
    /// The caret the proxy shows since WebKit's last report.
    private var shownAsIssued: Int?
    private(set) var adjustmentCount = 0

    init(text: String, caret: Int? = nil, unit: CursorOffsetUnit = .utf16, model: FakeContextModel = .whole,
         window: Int? = nil, lagFrames: Int = 0, callbackFrames: Int? = 1, provisionalContext: Bool = false) {
        units = Array(text.utf16)
        self.caret = caret ?? text.utf16.count
        self.unit = unit
        self.model = model
        self.window = window
        self.lagFrames = lagFrames
        self.callbackFrames = callbackFrames
        self.provisionalContext = provisionalContext
    }

    /// The host's configuration and what it still has to do, for the typing torture's trace.
    var traceDescription: String {
        "\(unit) \(model) lag \(lagFrames) callbacks \(callbackFrames.map(String.init) ?? "none") provisional "
            + "\(provisionalContext) twice \(reportsAsIssuedFirst) shows \(shownAsIssued.map(String.init) ?? "-") "
            + "provisional caret \(provisional.map { String($0.caret) } ?? "-") stale \(isContextStale) queued "
            + "\(queued.map(\.offset)) reports due \(callbacks.map(\.frames))"
    }

    mutating func adjust(by offset: Int) {
        adjustmentCount += 1
        if provisionalContext {
            let shown = provisional ?? {
                let context = self.context
                return (Array((context.before + context.after).utf16), context.before.utf16.count)
            }()
            provisional = (shown.units, min(max(shown.caret + offset, 0), shown.units.count))
        }
        queued.append((offset, lagFrames))
        advanceFrame(applyingDueOnly: true)
    }

    /// Lets one display frame pass; lagging adjustments land when due.
    mutating func advanceFrame(applyingDueOnly: Bool = false) {
        if !applyingDueOnly {
            queued = queued.map { (offset: $0.offset, frames: $0.frames - 1) }
            callbacks = callbacks.map { (frames: $0.frames - 1, shows: $0.shows) }
            if let stale = staleContext {
                staleContext = stale.frames > 1 ? (stale.before, stale.after, stale.frames - 1) : nil
            }
        }
        while let first = queued.first, first.frames <= 0 {
            queued.removeFirst()
            apply(first.offset)
        }
    }

    /// The next `textDidChange` due now, as the context the proxy shows when it arrives. The first one
    /// replaces any provisional context.
    mutating func takeCallback() -> (before: String, after: String)? {
        guard let index = callbacks.firstIndex(where: { $0.frames <= 0 }) else { return nil }
        let callback = callbacks.remove(at: index)
        provisional = nil
        staleContext = nil
        shownAsIssued = callback.shows
        return context
    }

    // MARK: Edits

    /// Selected code units after the caret; the context after starts past them.
    private(set) var selectionLength = 0

    var hasSelection: Bool { selectionLength > 0 }

    /// The text changed: reports still to come show it as it is, not a caret it no longer has.
    private mutating func forgetShownCarets() {
        shownAsIssued = nil
        callbacks = callbacks.map { (frames: $0.frames, shows: nil) }
    }

    /// Adjustments or callbacks are still to come.
    var hasCallbacksToCome: Bool { !queued.isEmpty || !callbacks.isEmpty }

    /// Where the caret will be once the adjustments still lagging have landed (where the next edit acts),
    /// without letting them land.
    var caretOnceAdjusted: Int {
        var landed = self
        landed.applyQueuedAdjustments()
        return landed.caret
    }

    /// Adjustments still lagging land first: the host applies the proxy's operations in order.
    mutating func applyQueuedAdjustments() {
        while !queued.isEmpty { apply(queued.removeFirst().offset) }
    }

    /// Inserts at the caret, replacing any selection.
    mutating func insertText(_ inserted: String) {
        applyQueuedAdjustments()
        edited()
        provisional = nil
        forgetShownCarets()
        units.replaceSubrange(caret ..< caret + selectionLength, with: Array(inserted.utf16))
        caret += inserted.utf16.count
        selectionLength = 0
    }

    /// Deletes the selection, or the grapheme before the caret, as UIKit does (a decomposed é goes
    /// whole; so does "\r\n").
    mutating func deleteBackward() {
        applyQueuedAdjustments()
        edited()
        provisional = nil
        forgetShownCarets()
        if selectionLength > 0 {
            units.removeSubrange(caret ..< caret + selectionLength)
            selectionLength = 0
            return
        }
        guard caret > 0 else { return }
        let offsets = graphemeOffsets()
        let start = offsets.last { $0 < caret } ?? 0
        units.removeSubrange(start ..< caret)
        caret = start
    }

    /// The host app moves the caret (a tap, or code).
    mutating func moveCaret(to offset: Int) {
        provisional = nil
        forgetShownCarets()
        selectionLength = 0
        caret = min(max(offset, 0), text.utf16.count)
    }

    /// The host app selects `length` code units from `offset`.
    mutating func select(from offset: Int, length: Int) {
        moveCaret(to: offset)
        selectionLength = max(0, min(length, text.utf16.count - caret))
    }

    private mutating func apply(_ offset: Int) {
        let issued = caret
        let total = text.utf16.count
        switch unit {
        case .utf16:
            let target = caret + offset
            if (0...total).contains(target) { caret = target }
        case .grapheme:
            let offsets = graphemeOffsets()
            if let index = offsets.firstIndex(of: caret) {
                let target = index + offset
                if offsets.indices.contains(target) { caret = offsets[target] }
            }
        }
        if let callbackFrames {
            if reportsAsIssuedFirst {
                callbacks.append((callbackFrames, issued))
                callbacks.append((callbackFrames + 1, caret))
            } else {
                callbacks.append((callbackFrames, nil))
            }
        }
    }

    /// Character boundaries in `units`. The lossy `text` has the same offsets: each lone surrogate half
    /// is one U+FFFD, one unit long, and its own character.
    private func graphemeOffsets() -> [Int] {
        var offsets = [0], offset = 0
        for character in text {
            offset += character.utf16.count
            offsets.append(offset)
        }
        return offsets
    }

    /// Sentence ranges (UTF-16, with trailing spaces and line breaks), as Foundation finds them.
    private func sentences() -> [Range<Int>] {
        let string = text as NSString
        var ranges: [Range<Int>] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                                   options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            ranges.append(enclosing.location ..< enclosing.location + enclosing.length)
        }
        return ranges
    }

    /// What the proxy reports now.
    var context: (before: String, after: String) {
        if let provisional {
            return (String(decoding: provisional.units[..<provisional.caret], as: UTF16.self),
                    String(decoding: provisional.units[provisional.caret...], as: UTF16.self))
        }
        if let shownAsIssued { return window(at: shownAsIssued) }
        if let staleContext { return (staleContext.before, staleContext.after) }
        return liveContext
    }

    /// The span of the field (UTF-16 offsets) the proxy shows now, when it shows the field as it is: not a
    /// provisional answer, a report's caret, or a view our edits have not reached yet.
    var liveWindow: Range<Int>? {
        guard provisional == nil, shownAsIssued == nil, staleContext == nil else { return nil }
        let shown = liveContext
        return (caret - shown.before.utf16.count) ..< (caret + selectionLength + shown.after.utf16.count)
    }

    /// The context as the field is now. With a selection, the context before ends at its start and the
    /// one after begins at its end.
    var liveContext: (before: String, after: String) {
        (window(at: caret).before, window(at: caret + selectionLength).after)
    }

    // MARK: Lagging contexts

    /// The proxy shows the keyboard's own edits only this many frames later (until then, the field as it
    /// was before the first edit not shown yet), or at the next callback, which refreshes it.
    var editContextLagFrames = 0
    private var staleContext: (before: String, after: String, frames: Int)?

    /// The proxy still shows the field as it was before some of the keyboard's own edits.
    var isContextStale: Bool { staleContext != nil }

    /// A callback brought the proxy the field as it is.
    mutating func refreshContext() {
        staleContext = nil
    }

    private mutating func edited() {
        guard editContextLagFrames > 0, staleContext == nil else { return }
        let shown = context
        staleContext = (shown.before, shown.after, editContextLagFrames)
    }

    // MARK: The host app's own edits

    /// The host app inserts text at a UTF-16 offset (a boundary, outside any selection).
    mutating func hostInsert(_ inserted: String, at offset: Int) {
        units.insert(contentsOf: Array(inserted.utf16), at: offset)
        if offset <= caret { caret += inserted.utf16.count }
        provisional = nil
        staleContext = nil
        forgetShownCarets()
    }

    /// The host app deletes a range of UTF-16 offsets (on boundaries); a selection is dropped.
    mutating func hostDelete(_ range: Range<Int>) {
        units.removeSubrange(range)
        if caret >= range.upperBound {
            caret -= range.count
        } else if caret > range.lowerBound {
            caret = range.lowerBound
        }
        selectionLength = 0
        provisional = nil
        staleContext = nil
        forgetShownCarets()
    }

    private func window(at caret: Int) -> (before: String, after: String) {
        var start = 0, end = units.count
        switch model {
        case .whole:
            break
        case .uikit:
            let ranges = sentences()
            if caret > 0, let ending = ranges.lastIndex(where: { $0.lowerBound <= caret - 1 }) {
                start = ranges[max(ending - 2, 0)].lowerBound
            }
            end = ranges.first(where: { $0.contains(caret) })?.upperBound ?? caret
            if let lineBreak = units[caret ..< max(end, caret)].firstIndex(of: 10) { end = lineBreak }
        case .lineBreakOnly:
            if let lineBreak = units[..<caret].lastIndex(of: 10) { start = lineBreak == caret - 1 ? lineBreak : lineBreak + 1 }
            if let lineBreak = units[caret...].firstIndex(of: 10) { end = lineBreak }
        }
        let offsets = graphemeOffsets()
        if let window {
            let before = offsets.filter { $0 <= caret }
            let after = offsets.filter { $0 >= caret }
            start = max(start, before[max(before.count - 1 - window, 0)])
            end = min(end, after[min(window, after.count - 1)])
        }
        // A caret inside a cluster splits it, as UIKit does; the proxy bridges a lone surrogate half as U+FFFD.
        let beforeText = String(decoding: units[min(start, caret) ..< caret], as: UTF16.self)
        let afterText = String(decoding: units[caret ..< max(end, caret)], as: UTF16.self)
        return (beforeText, afterText)
    }

    /// Whether the caret sits on a grapheme boundary.
    var caretIsOnBoundary: Bool { graphemeOffsets().contains(caret) }

    /// Whether the caret sits between the two halves of a surrogate pair.
    var caretSplitsSurrogatePair: Bool {
        guard caret > 0, caret < units.count else { return false }
        return UTF16.isLeadSurrogate(units[caret - 1]) && UTF16.isTrailSurrogate(units[caret])
    }
}

/// A field for `EditingCore`, `KeyboardEditor` and `TrackpadController`: a fake host with an identity.
/// The host app can move the caret, edit, and send callbacks the way the proxy delivers them.
final class FakeDocument: TextDocument, TrackpadHost {
    var host: FakeTextHost
    var documentID: UUID?
    /// The host reports our own `insertText` and `deleteBackward` with `textDidChange` this many run-loop
    /// turns later; nil reports nothing, as UIKit was measured to do.
    var editCallbackDelay: Int?
    /// A Return typed here moves focus to this other field, as a form's return key can: the host app
    /// sends what is typed next there at once, and the proxy shows the new field (and reports it)
    /// `returnFocusDelay` turns later.
    var returnMovesFocusTo: (host: FakeTextHost, id: UUID)?
    var returnFocusDelay = 1
    /// The host app moved focus here; the proxy has not caught up yet.
    private var routedTo: FakeTextHost?
    /// Host events still to come: in how many turns, an action, and the callback that reports it.
    private var scheduled: [(turns: Int, action: (() -> Void)?, textChanged: Bool)] = []

    init(_ host: FakeTextHost, documentID: UUID? = UUID()) {
        self.host = host
        self.documentID = documentID
    }

    var text: String { host.text }
    var contextBefore: String? { host.context.before.isEmpty ? nil : host.context.before }
    var contextAfter: String? { host.context.after.isEmpty ? nil : host.context.after }
    var hasSelection: Bool { host.hasSelection }

    func insertText(_ text: String) {
        if routedTo != nil {
            routedTo?.insertText(text)
            return
        }
        host.insertText(text)
        if let editCallbackDelay { scheduled.append((editCallbackDelay, nil, true)) }
        if text.contains("\n"), let other = returnMovesFocusTo {
            returnMovesFocusTo = nil
            routedTo = other.host
            scheduled.append((returnFocusDelay, { [weak self] in
                guard let self, let routed = self.routedTo else { return }
                self.routedTo = nil
                self.switchField(to: routed, id: other.id)
            }, true))
        }
    }

    func deleteBackward() {
        if routedTo != nil {
            routedTo?.deleteBackward()
            return
        }
        host.deleteBackward()
        if let editCallbackDelay { scheduled.append((editCallbackDelay, nil, true)) }
    }

    func adjust(by offset: Int) {
        host.adjust(by: offset)
    }

    // MARK: The host app

    /// Moves the caret (a tap, or code), reported next turn by `selectionDidChange` or `textDidChange`.
    func moveCaret(to offset: Int, reportedAsTextChange: Bool = false) {
        host.moveCaret(to: offset)
        scheduled.append((1, nil, reportedAsTextChange))
    }

    /// Selects text, reported next turn by `selectionDidChange`.
    func select(from offset: Int, length: Int) {
        host.select(from: offset, length: length)
        scheduled.append((1, nil, false))
    }

    /// Focus moves to another field, reported next turn by `textDidChange`.
    func focus(_ other: FakeTextHost, id: UUID?) {
        scheduled.append((1, { [weak self] in self?.switchField(to: other, id: id) }, true))
    }

    /// Focus moves at once, before any callback reports it (the proxy already serves the new field).
    func switchField(to other: FakeTextHost, id: UUID?) {
        previousHosts.append(host)
        host = other
        documentID = id
    }

    /// The fields focus left, oldest first.
    private(set) var previousHosts: [FakeTextHost] = []

    /// Callbacks still scheduled.
    var pendingCallbacks: Int { scheduled.count }

    /// One run-loop turn, at `now`: due host events happen and their callbacks reach `core`, in order.
    @discardableResult
    func pump(_ core: EditingCore, at now: TimeInterval) -> [EditingCore.CallbackOutcome] {
        pump { core.hostChanged(textChanged: $0, now: now) }
    }

    /// The same, delivered to the keyboard's editing side as the keyboard does.
    @discardableResult
    func pump(_ editor: KeyboardEditor, at now: TimeInterval) -> [EditingCore.CallbackOutcome] {
        pump { editor.hostChanged(textChanged: $0, now: now) }
    }

    /// One run-loop turn: due host events happen, and each callback (which brings the proxy the field as
    /// it is) goes to `deliver`.
    func pump(_ deliver: (Bool) -> EditingCore.CallbackOutcome) -> [EditingCore.CallbackOutcome] {
        scheduled = scheduled.map { (turns: $0.turns - 1, action: $0.action, textChanged: $0.textChanged) }
        var outcomes: [EditingCore.CallbackOutcome] = []
        while let index = scheduled.firstIndex(where: { $0.turns <= 0 }) {
            let event = scheduled.remove(at: index)
            event.action?()
            host.refreshContext()
            outcomes.append(deliver(event.textChanged))
        }
        return outcomes
    }

    /// The host app inserts text at a UTF-16 offset, reported `turns` turns later.
    func hostInserts(_ text: String, at offset: Int, reportAfter turns: Int = 1) {
        host.hostInsert(text, at: offset)
        scheduled.append((turns, nil, true))
    }

    /// The host app deletes a range of UTF-16 offsets, reported `turns` turns later.
    func hostDeletes(_ range: Range<Int>, reportAfter turns: Int = 1) {
        host.hostDelete(range)
        scheduled.append((turns, nil, true))
    }

    /// A callback `turns` turns from now, about the field as it is then.
    func report(after turns: Int, textChanged: Bool = true) {
        scheduled.append((turns, nil, textChanged))
    }
}

/// An owner of adjustments for `EditingCore` tests: active while told, and explaining callbacks as
/// told.
final class FakeAdjustments: AdjustmentOwner {
    var isActive = false
    var explains = true
    private(set) var acknowledged = 0

    func acknowledge(before: String?, after: String?) -> Bool {
        if explains { acknowledged += 1 }
        return explains
    }

    func fits(before: String?, after: String?) -> Bool { explains }
}

/// One display frame: the host's due `textDidChange` callbacks reach the session as in
/// `KeyboardInput`, then the session reads the context and may adjust. A callback the session cannot
/// explain would end the gesture, so it fails the test.
func runFrame(_ session: inout TrackpadSession, host: inout FakeTextHost, at time: TimeInterval) {
    host.advanceFrame()
    while let context = host.takeCallback() {
        TestSupport.expect(session.acknowledge(before: context.before, after: context.after),
                           "a callback for the session's own adjustment was not explained")
    }
    let context = host.context
    if let offset = session.frame(before: context.before, after: context.after, timestamp: time) {
        host.adjust(by: offset)
    }
}

/// Drives a session against a host: one touch event per 120 Hz frame, then a rest and the lift (or a
/// system cancellation, whose rollback is issued at once) and the settling frames. Returns the time
/// after the gesture.
@discardableResult
func runGesture(_ session: inout TrackpadSession, host: inout FakeTextHost, samples: [(dx: Double, dy: Double)],
                start: TimeInterval = 100, frameInterval: TimeInterval = 1.0 / 120, end: Bool = true,
                cancel: Bool = false, restFrames: Int = 90) -> TimeInterval {
    var time = start
    func frame() {
        runFrame(&session, host: &host, at: time)
    }
    for sample in samples {
        session.drag(dx: sample.dx, dy: sample.dy)
        frame()
        time += frameInterval
    }
    // Let edge probes and re-snapshots finish while the finger rests.
    for _ in 0 ..< restFrames {
        frame()
        time += frameInterval
    }
    guard end || cancel else { return time }
    if cancel {
        if let rollback = session.cancel(at: time) { host.adjust(by: rollback) }
    } else {
        session.end(at: time)
    }
    for _ in 0 ..< 120 where !session.isFinished(at: time) {
        frame()
        time += frameInterval
    }
    // Whatever is still in flight lands.
    for _ in 0 ..< 10 { host.advanceFrame() }
    return time
}

func makeSession(_ host: FakeTextHost, unit: CursorOffsetUnit? = nil, reportsTwice: Bool? = nil, columns: Int = 1_000,
                 advance: ((String) -> Double)? = nil, layoutWidth: Double = 10_000,
                 parameters: TrackpadParameters = .flat) -> TrackpadSession {
    let context = host.context
    return TrackpadSession(before: context.before, after: context.after, unit: unit, reportsTwice: reportsTwice,
                           parameters: parameters,
                           layout: FixedWidthLayout(columns: columns, advance: advance), linePitch: 20,
                           layoutWidth: layoutWidth)
}

/// `samples` touch events of the same step.
func slowDrag(dx: Double = 0, dy: Double = 0, samples: Int) -> [(dx: Double, dy: Double)] {
    Array(repeating: (dx, dy), count: samples)
}

extension TrackpadParameters {
    /// Gain 1 for every step, so positional tests count exact distances. The measured curve has its
    /// own tests.
    static var flat: TrackpadParameters {
        var parameters = TrackpadParameters.standard
        parameters.quadraticCoefficient = 0
        parameters.linearSlope = 0
        parameters.powerCoefficient = 1
        parameters.powerExponent = 0
        return parameters
    }
}
