import Foundation

/// Lays text out in fixed-width columns: `columns` graphemes per line (wrapping anywhere), line
/// breaks end lines, and every grapheme is `width` points wide.
struct FixedWidthLayout: LineLayout {
    var columns: Int
    var width: Double = 10

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
        var position = 0, count = 0
        for character in text {
            if position >= offset { break }
            if position >= line.lowerBound { count += 1 }
            position += character.utf16.count
        }
        return Double(count) * width
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
    private var queued: [(offset: Int, frames: Int)] = []
    private(set) var adjustmentCount = 0

    init(text: String, caret: Int? = nil, unit: CursorOffsetUnit = .utf16, window: Int? = nil,
         windowStopsAtLineBreaks: Bool = false, lagFrames: Int = 0) {
        self.text = text
        self.caret = caret ?? text.utf16.count
        self.unit = unit
        self.window = window
        self.windowStopsAtLineBreaks = windowStopsAtLineBreaks
        self.lagFrames = lagFrames
    }

    mutating func adjust(by offset: Int) {
        adjustmentCount += 1
        queued.append((offset, lagFrames))
        advanceFrame(applyingDueOnly: true)
    }

    /// Lets one display frame pass; lagging adjustments land when due.
    mutating func advanceFrame(applyingDueOnly: Bool = false) {
        if !applyingDueOnly { queued = queued.map { (offset: $0.offset, frames: $0.frames - 1) } }
        while let first = queued.first, first.frames <= 0 {
            queued.removeFirst()
            apply(first.offset)
        }
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
}

/// Drives a session against a host: one touch sample per 120 Hz frame, then the lift and the
/// settling frames. Returns the time after the gesture.
@discardableResult
func runGesture(_ session: inout TrackpadSession, host: inout FakeTextHost, samples: [(dx: Double, dy: Double)],
                start: TimeInterval = 100, frameInterval: TimeInterval = 1.0 / 120, end: Bool = true) -> TimeInterval {
    var time = start
    func frame() {
        host.advanceFrame()
        let context = host.context
        if let offset = session.frame(before: context.before, after: context.after, timestamp: time) {
            host.adjust(by: offset)
        }
    }
    for sample in samples {
        session.drag(dx: sample.dx, dy: sample.dy, timestamp: time)
        frame()
        time += frameInterval
    }
    // Let edge probes and re-snapshots finish while the finger rests.
    for _ in 0 ..< 90 {
        frame()
        time += frameInterval
    }
    guard end else { return time }
    session.end(at: time)
    for _ in 0 ..< 120 where !session.isFinished(at: time) {
        frame()
        time += frameInterval
    }
    return time
}

func makeSession(_ host: FakeTextHost, unit: CursorOffsetUnit? = nil, columns: Int = 1_000,
                 parameters: TrackpadParameters = .standard) -> TrackpadSession {
    let context = host.context
    return TrackpadSession(before: context.before, after: context.after, unit: unit, parameters: parameters,
                           layout: FixedWidthLayout(columns: columns), lineHeight: 20, advance: testAdvance)
}

/// `count` slow samples of `step` points each (60 points per second at 120 Hz: gain 1).
func slowDrag(dx: Double = 0, dy: Double = 0, samples: Int) -> [(dx: Double, dy: Double)] {
    Array(repeating: (dx, dy), count: samples)
}
