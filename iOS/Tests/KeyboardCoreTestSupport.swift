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

/// A host document as a keyboard sees it through the proxy, with the behavior measured in the
/// simulator: `adjustTextPosition` counts UTF-16 code units (UIKit) or grapheme clusters (WebKit),
/// an offset past either end is ignored, the context window can be limited and stop at line
/// breaks (UIKit), and adjustments can land a few frames late.
struct FakeTextHost {
    var text: String
    /// The caret as a UTF-16 offset.
    private(set) var caret: Int
    var unit: CursorOffsetUnit
    /// Graphemes shown on each side of the caret; nil shows everything.
    var window: Int?
    /// UIKit's window stops at line breaks; only "\n" itself shows, right after one.
    var windowStopsAtLineBreaks: Bool
    var lagFrames: Int
    /// `textDidChange` arrives this many frames after each adjustment lands, even an ignored one (the
    /// proxy shows the caret unmoved afterwards, as measured); nil sends none.
    var callbackFrames: Int?
    /// As measured in UIKit: until that callback the proxy answers from the context it last reported,
    /// the caret moved by the offset in code units and clamped to that text.
    var provisionalContext: Bool
    private var queued: [(offset: Int, frames: Int)] = []
    private var callbacks: [Int] = []
    private var provisional: (units: [UInt16], caret: Int)?
    private(set) var adjustmentCount = 0

    init(text: String, caret: Int? = nil, unit: CursorOffsetUnit = .utf16, window: Int? = nil,
         windowStopsAtLineBreaks: Bool = false, lagFrames: Int = 0, callbackFrames: Int? = 1,
         provisionalContext: Bool = false) {
        self.text = text
        self.caret = caret ?? text.utf16.count
        self.unit = unit
        self.window = window
        self.windowStopsAtLineBreaks = windowStopsAtLineBreaks
        self.lagFrames = lagFrames
        self.callbackFrames = callbackFrames
        self.provisionalContext = provisionalContext
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
            callbacks = callbacks.map { $0 - 1 }
        }
        while let first = queued.first, first.frames <= 0 {
            queued.removeFirst()
            apply(first.offset)
        }
    }

    /// The `textDidChange` callbacks due now. The first one replaces any provisional context.
    mutating func takeCallbacks() -> Int {
        let due = callbacks.filter { $0 <= 0 }.count
        callbacks.removeAll { $0 <= 0 }
        if due > 0 { provisional = nil }
        return due
    }

    private mutating func apply(_ offset: Int) {
        let total = text.utf16.count
        switch unit {
        case .utf16:
            let target = caret + offset
            if (0...total).contains(target) { caret = target }
        case .grapheme:
            let offsets = graphemeOffsets()
            guard let index = offsets.firstIndex(of: caret) else { return }
            let target = index + offset
            if offsets.indices.contains(target) { caret = offsets[target] }
        }
        if let callbackFrames { callbacks.append(callbackFrames) }
    }

    private func graphemeOffsets() -> [Int] {
        var offsets = [0], offset = 0
        for character in text {
            offset += character.utf16.count
            offsets.append(offset)
        }
        return offsets
    }

    /// What the proxy reports now.
    var context: (before: String, after: String) {
        if let provisional {
            return (String(decoding: provisional.units[..<provisional.caret], as: UTF16.self),
                    String(decoding: provisional.units[provisional.caret...], as: UTF16.self))
        }
        let units = Array(text.utf16)
        var start = 0, end = units.count
        if windowStopsAtLineBreaks {
            // As measured in UIKit: right after a line break the context before is just "\n";
            // further into the line it starts after the break. After never includes the break.
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
        // A caret inside a cluster splits it, as UIKit does.
        let beforeText = String(decoding: units[min(start, caret) ..< caret], as: UTF16.self)
        let afterText = String(decoding: units[caret ..< max(end, caret)], as: UTF16.self)
        return (beforeText, afterText)
    }

    /// Whether the caret sits on a grapheme boundary.
    var caretIsOnBoundary: Bool { graphemeOffsets().contains(caret) }

    /// Whether the caret sits between the two halves of a surrogate pair.
    var caretSplitsSurrogatePair: Bool {
        let units = Array(text.utf16)
        guard caret > 0, caret < units.count else { return false }
        return UTF16.isLeadSurrogate(units[caret - 1]) && UTF16.isTrailSurrogate(units[caret])
    }
}

/// One display frame: the host's due `textDidChange` callbacks reach the session as in
/// `KeyboardInput`, then the session reads the context and may adjust. A callback the session cannot
/// explain would end the gesture, so it fails the test.
func runFrame(_ session: inout TrackpadSession, host: inout FakeTextHost, at time: TimeInterval) {
    host.advanceFrame()
    for _ in 0 ..< host.takeCallbacks() {
        let context = host.context
        TestSupport.expect(session.explains(before: context.before, after: context.after),
                           "a callback for the session's own adjustment was not explained")
        session.hostDidChange()
    }
    let context = host.context
    if let offset = session.frame(before: context.before, after: context.after, timestamp: time) {
        host.adjust(by: offset)
    }
}

/// Drives a session against a host: one touch event per 120 Hz frame, then a rest and the lift (or a
/// system cancellation) and the settling frames. Returns the
/// time after the gesture.
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
        session.cancel(at: time)
    } else {
        session.end(at: time)
    }
    for _ in 0 ..< 120 where !session.isFinished(at: time) {
        frame()
        time += frameInterval
    }
    return time
}

func makeSession(_ host: FakeTextHost, unit: CursorOffsetUnit? = nil, columns: Int = 1_000,
                 advance: ((String) -> Double)? = nil, layoutWidth: Double = 10_000,
                 parameters: TrackpadParameters = .flat) -> TrackpadSession {
    let context = host.context
    return TrackpadSession(before: context.before, after: context.after, unit: unit, parameters: parameters,
                           layout: FixedWidthLayout(columns: columns, advance: advance), lineHeight: 20,
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
