import Foundation

/// One trackpad gesture over the text the proxy exposes, modeled on Apple's floating cursor
/// (ARCHITECTURE.md, "Measured Apple keyboard behavior"). A 2D point starts at the caret in the
/// layout of the context snapshot and moves by the measured per-event gain. The caret is the
/// character boundary nearest the point on the line whose center is nearest the point's y. Line ends
/// do not wrap; only vertical motion changes lines; the point is clamped and overshoot is forgotten.
///
/// The keyboard feeds it touch events and, once per display frame, what the proxy reports; it
/// answers with at most one offset for `adjustTextPosition(byCharacterOffset:)`. Pure, so the loop
/// is tested against a simulated host.
///
/// The proxy shows only a window of text around the caret (in UIKit, a sentence or two before it,
/// often starting mid-line, and after it up to the end of the sentence or line), and its context
/// updates after an adjustment at once or a little later. So the caret moves virtually inside a
/// snapshot. The snapshot is refreshed when the caret reaches its edge and the host shows more, and
/// the point is re-anchored to the caret's line. A line beyond the window is reached by one jump
/// past the snapshot's edge; at the document's edge the host ignores such an offset, so the caret
/// stays put. Columns are real only on lines whose start the snapshot shows: when a vertical move
/// lands the caret on a line whose start is hidden and the host then shows more of it, the snapshot
/// is refreshed and the point keeps its column.
///
/// Safety rules (ARCHITECTURE.md, "Trackpad safety"):
/// - The unit is learned only from fresh, discriminating evidence: the context must agree with the
///   caret where that unit puts it, and must have changed by exactly that many code units. A probe
///   steps across a multi-unit cluster by its UTF-16 length, so neither unit leaves the caret inside
///   it (or by the crossing-side scalar when the snapshot has too few clusters, never mid-pair).
/// - A probe is read only once the host has sent `textDidChange` for every adjustment, or after the
///   timeout: the proxy's immediate answer is provisional. A context that shows the caret exactly at
///   the snapshot's edge is never read as a crossing.
/// - An unchanged context after an edge probe is ambiguous (an ignored step at the document's edge
///   looks the same as a move between blank lines), never a boundary. The overshoot is dropped, so
///   further probes need new finger travel, and they are bounded.
/// - Cancellation moves the caret back to where an outstanding probe started.
/// The keyboard re-validates the field and the edit generation before every adjustment.
struct TrackpadSession {
    struct Context: Equatable {
        var before: String
        var after: String
        /// The text starts a line: the host showed the line break before it, or nothing at all (the
        /// document's start).
        var startsLine = false
    }

    enum Edge: Hashable { case start, end }

    private enum Flight {
        case move
        /// `step` units across the cluster after `from`.
        case unitProbe(from: Int, direction: Int, step: Int)
        /// A jump just past the snapshot's edge, to reveal the line beyond it.
        case edgeProbe(Edge)
    }

    let parameters: TrackpadParameters
    /// Known from an earlier gesture in this field, or learned from discriminating evidence.
    private(set) var unit: CursorOffsetUnit?
    private(set) var navigator: TextNavigator
    /// Where the host's caret is, or will be once the adjustment in flight lands.
    private(set) var committed: Int
    /// The floating point, in the snapshot's layout.
    private(set) var point: FloatingCursor
    /// Edge probes at each edge whose outcome was ambiguous since the context last changed.
    private(set) var ambiguousProbes: [Edge: Int] = [:]
    private(set) var isCancelled = false
    private let layout: any LineLayout
    private let lineHeight: Double
    private let layoutWidth: Double
    private var lines: [Range<Int>]
    /// Lines before this one may start before the snapshot does (UIKit's context begins about a
    /// sentence back, often mid-line), so their columns are estimates.
    private var firstAnchoredLine = 0
    /// The point's x is a real column: it was last placed on an anchored line.
    private var xIsReal = false
    private var snapshotContext: Context
    /// The point is on a line the snapshot does not show.
    private var blocked: Edge?
    private var flight: (kind: Flight, issuedAt: TimeInterval, context: Context)?
    private var endedAt: TimeInterval?
    private var lastIssuedAt: TimeInterval?
    /// Adjustments whose `textDidChange` has not arrived. Measured in UIKit: the proxy answers an
    /// adjustment at once from the context it last reported, clamped to that text, and the host's own
    /// context follows with `textDidChange` about 10 ms later. A jump past the window's edge therefore
    /// reads first as the caret sitting at that edge. Probes are read only once every adjustment has
    /// been acknowledged, or after the timeout.
    private var unacknowledged = 0

    init(before: String?, after: String?, unit: CursorOffsetUnit?, parameters: TrackpadParameters,
         layout: any LineLayout, lineHeight: Double, layoutWidth: Double) {
        self.parameters = parameters
        self.unit = unit
        self.layout = layout
        self.lineHeight = max(lineHeight, 1)
        self.layoutWidth = max(layoutWidth, 2 * parameters.horizontalInset + 1)
        snapshotContext = Self.visible(before: before, after: after)
        navigator = TextNavigator(before: snapshotContext.before, after: snapshotContext.after)
        committed = navigator.cursor
        lines = layout.lines(in: navigator.text)
        let line = navigator.line(of: navigator.cursor, in: lines)
        // The point starts exactly at the caret.
        point = FloatingCursor(parameters: parameters, x: navigator.x(of: navigator.cursor, lines: lines, layout: layout),
                               y: (Double(line) + 0.5) * max(lineHeight, 1))
        firstAnchoredLine = Self.firstAnchoredLine(navigator.text, lines: lines, startsLine: snapshotContext.startsLine)
        xIsReal = line >= firstAnchoredLine
    }

    /// Nothing is in flight and the host has been told where the caret is.
    var isSettled: Bool { flight == nil && committed == navigator.cursor }

    var isEnded: Bool { endedAt != nil }

    /// A unit probe is outstanding: the caret may be past or inside a cluster until it is resolved.
    var hasOutstandingProbe: Bool {
        if case .unitProbe? = flight?.kind { return true }
        return false
    }

    func isSoftEdge(_ edge: Edge) -> Bool {
        ambiguousProbes[edge, default: 0] >= parameters.maximumAmbiguousProbes
    }

    /// After the finger lifts: settled, or out of time to finish. Each adjustment issued after the
    /// lift (a correction or a rollback) gets its own time to land.
    func isFinished(at timestamp: TimeInterval) -> Bool {
        guard let endedAt else { return false }
        return isSettled || timestamp - max(endedAt, lastIssuedAt ?? endedAt) >= parameters.settleTimeout
    }

    /// One delivered touch event's finger movement. The point moves at once; the caret follows.
    mutating func drag(dx: Double, dy: Double) {
        guard endedAt == nil else { return }
        point.move(dx: dx, dy: dy)
        retarget()
    }

    /// The finger lifted: the caret stops where it is headed (lift stops dead), and pending
    /// adjustments still land.
    mutating func end(at timestamp: TimeInterval) {
        guard endedAt == nil else { return }
        endedAt = timestamp
        blocked = nil
    }

    /// The system cancelled the gesture: stop where the host is, except that an outstanding probe is
    /// rolled back to where it started.
    mutating func cancel(at timestamp: TimeInterval) {
        end(at: timestamp)
        isCancelled = true
        if case .unitProbe(let from, _, _)? = flight?.kind {
            navigator.setCursor(from)
        } else {
            navigator.setCursor(committed)
        }
    }

    /// Call once per display frame with the proxy's current context. Returns the offset to pass to
    /// `adjustTextPosition`, if any.
    mutating func frame(before: String?, after: String?, timestamp: TimeInterval) -> Int? {
        let context = Self.visible(before: before, after: after)
        if let flight {
            let timedOut = timestamp - flight.issuedAt >= parameters.syncTimeout
            let fresh = context != flight.context
            switch flight.kind {
            case .move:
                if navigator.agrees(before: context.before, after: context.after, at: committed)
                    // Nothing to compare, but the host moved and has said so itself: take it as landed.
                    || (!navigator.canCompare(before: context.before, after: context.after, at: committed) && fresh
                        && unacknowledged == 0) {
                    self.flight = nil
                } else if timedOut {
                    // The host did something else; trust what it reports.
                    self.flight = nil
                    unacknowledged = 0
                    resnapshot(context)
                    retarget()
                } else {
                    return nil
                }
            case .unitProbe(let from, let direction, let step):
                guard (fresh && unacknowledged == 0) || timedOut else { return nil }
                self.flight = nil
                unacknowledged = 0
                if fresh {
                    if let offset = resolveProbe(from: from, direction: direction, step: step, issued: flight.context,
                                                 context: context, timestamp: timestamp) {
                        return issue(offset, at: timestamp)
                    }
                } else {
                    // Nothing observed in time: the step may land later or never. Learn nothing; the caret
                    // is where the host says, and only new finger travel asks again.
                    resnapshotAtCaret(context)
                }
            case .edgeProbe(let edge):
                // The caret at the snapshot's edge, not past it, is the proxy's provisional answer (or a
                // host that clamps instead of ignoring): no line was crossed.
                let crossed = fresh && !showsCaretAtEdge(edge, context)
                if crossed && (unacknowledged == 0 || timedOut) {
                    // The caret crossed into text the snapshot did not show: one line toward the point.
                    self.flight = nil
                    unacknowledged = 0
                    resnapshot(context, linesCrossed: edge == .end ? 1 : -1)
                    retarget()
                } else if timedOut {
                    // Unchanged, or still the provisional edge: the host ignored the jump (measured at
                    // the document's edge) and the caret is where it was.
                    self.flight = nil
                    unacknowledged = 0
                    ambiguousStep(at: edge)
                } else {
                    return nil
                }
            }
        }
        if let offset = nextAdjustment(timestamp: timestamp, context: context) { return issue(offset, at: timestamp) }
        guard endedAt == nil else { return nil }
        return extendSnapshot(context, timestamp: timestamp).map { issue($0, at: timestamp) }
    }

    /// Whether a host callback fits this session's own adjustments: the context shows the caret where
    /// an adjustment in flight will put it, or still where it was.
    func explains(before: String?, after: String?) -> Bool {
        let context = Self.visible(before: before, after: after)
        if context == snapshotContext { return true }
        if let flight {
            if flight.context == context { return true }
            // A probe lands where the snapshot cannot always confirm it.
            if case .move = flight.kind {} else { return true }
        }
        return navigator.agrees(before: context.before, after: context.after, at: committed)
    }

    /// The host's `textDidChange` for one of this session's adjustments: the context now read is the
    /// host's own.
    mutating func hostDidChange() {
        unacknowledged = max(unacknowledged - 1, 0)
    }

    private mutating func issue(_ offset: Int, at timestamp: TimeInterval) -> Int {
        lastIssuedAt = timestamp
        if offset != 0 { unacknowledged += 1 }
        return offset
    }

    /// The context as the session reads it. A before-context that starts with a line break (UIKit
    /// shows just "\n" right after one) ends a line whose text is hidden; the break is dropped, so the
    /// snapshot's first line is a real one and reaching the line above takes an edge probe.
    private static func visible(before: String?, after: String?) -> Context {
        var before = before ?? ""
        let startsLine = before.isEmpty || before.first?.isNewline == true
        if before.first?.isNewline == true { before.removeFirst() }
        return Context(before: before, after: after ?? "", startsLine: startsLine)
    }

    /// The first line known to start where the snapshot shows it: the first, if the snapshot starts a
    /// line; else the one after the first line break; else none.
    private static func firstAnchoredLine(_ text: String, lines: [Range<Int>], startsLine: Bool) -> Int {
        if startsLine { return 0 }
        var offset = 0
        for character in text {
            offset += character.utf16.count
            if character.isNewline { return lines.firstIndex { $0.lowerBound >= offset } ?? lines.count }
        }
        return lines.count
    }

    /// Whether the context shows the caret exactly at the snapshot's edge with nothing beyond it.
    private func showsCaretAtEdge(_ edge: Edge, _ context: Context) -> Bool {
        switch edge {
        case .end:
            return context.after.isEmpty && navigator.agrees(before: context.before, after: "", at: navigator.lastPosition)
        case .start:
            return context.before.isEmpty && navigator.agrees(before: "", after: context.after, at: 0)
        }
    }

    // MARK: The point

    private func center(_ line: Int) -> Double { (Double(line) + 0.5) * lineHeight }

    /// Clamps the point and sends the virtual caret to the boundary nearest it.
    private mutating func retarget() {
        guard endedAt == nil, !lines.isEmpty else { return }
        let last = lines.count - 1
        let reach = parameters.pendingLines * lineHeight
        let top = isSoftEdge(.start) ? center(0) - parameters.topOvershoot : center(0) - reach
        let bottom = isSoftEdge(.end) ? center(last) + parameters.bottomOvershoot : center(last) + reach
        point.clamp(x: parameters.horizontalInset ... layoutWidth - parameters.horizontalInset, y: top ... bottom)
        // The line whose center is nearest the point.
        let ideal = Int((point.y / lineHeight).rounded(.down))
        blocked = ideal < 0 ? .start : (ideal > last ? .end : nil)
        let line = min(max(ideal, 0), last)
        navigator.setCursor(navigator.position(nearestX: point.x, onLine: line, lines: lines, layout: layout))
    }

    /// An edge probe left the context unchanged: the host ignored it (the document's edge) or moved
    /// between places that look alike (blank lines). Neither is known, so the overshoot is dropped (the
    /// next probe needs new travel); after a bounded number the edge is held like Apple's last line.
    private mutating func ambiguousStep(at edge: Edge) {
        ambiguousProbes[edge, default: 0] += 1
        let last = lines.count - 1
        let margin = 0.45 * lineHeight
        let top = edge == .start ? center(0) - min(parameters.topOvershoot, margin) : -Double.greatestFiniteMagnitude
        let bottom = edge == .end ? center(last) + min(parameters.bottomOvershoot, margin) : Double.greatestFiniteMagnitude
        point.clamp(x: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude, y: top ... bottom)
        retarget()
    }

    // MARK: Units

    /// Reads a probe's outcome from a changed context. Returns an offset to issue at once: the rest of
    /// the cluster when a UTF-16 host stopped inside it, or the way back after cancellation.
    ///
    /// Evidence must discriminate: the context must agree with the caret where that unit would put it,
    /// and the context must have shrunk on one side and grown on the other by exactly the code units
    /// that unit would cross. Repetitive text ("e\u{301}e\u{301}") can agree with several carets, but not
    /// with several move lengths; a window that merely widened or shifted fits neither.
    private mutating func resolveProbe(from: Int, direction: Int, step: Int, issued: Context, context: Context,
                                       timestamp: TimeInterval) -> Int? {
        let clusterLength = abs(navigator.utf16Distance(from: from, to: from + direction))
        let utf16Split = navigator.boundaries[from] + direction * step
        let graphemePosition = from + direction * step
        let shrunk = context.before.utf16.count - issued.before.utf16.count
        let grown = context.after.utf16.count - issued.after.utf16.count
        func moved(by units: Int) -> Bool { shrunk == direction * units && grown == -direction * units }
        let utf16 = moved(by: step) && navigator.agrees(before: context.before, after: context.after, atUTF16: utf16Split)
        let grapheme = navigator.boundaries.indices.contains(graphemePosition)
            && moved(by: abs(navigator.utf16Distance(from: from, to: graphemePosition)))
            && navigator.agrees(before: context.before, after: context.after, at: graphemePosition)
        switch (utf16, grapheme) {
        case (true, false):
            unit = .utf16
            if step >= clusterLength {
                committed = from + direction
                return nil
            }
            // Inside the cluster: finish crossing it, or after cancellation go back to its start.
            committed = isCancelled ? from : from + direction
            flight = (.move, timestamp, context)
            return isCancelled ? -direction * step : direction * (clusterLength - step)
        case (false, true):
            // Past `step` whole clusters; the next adjustment moves back if that overshot.
            unit = .grapheme
            committed = graphemePosition
            return nil
        default:
            // Moved somewhere this snapshot cannot place: trust the host, learn nothing.
            resnapshotAtCaret(context)
            return nil
        }
    }

    /// The probe step for the cluster after `from`: its UTF-16 length when the snapshot has that many
    /// clusters to spare (both units then cross whole clusters), else the length of the scalar on
    /// the crossing side, which keeps a UTF-16 host off a surrogate pair's middle.
    private func probeStep(from: Int, direction: Int) -> Int {
        let length = abs(navigator.utf16Distance(from: from, to: from + direction))
        if navigator.boundaries.indices.contains(from + direction * length) { return length }
        let cluster = navigator.grapheme(after: direction > 0 ? from : from - 1) ?? ""
        let scalar = direction > 0 ? cluster.unicodeScalars.first : cluster.unicodeScalars.last
        return min(length, max(1, scalar.map { UTF16.width($0) } ?? 1))
    }

    /// The host offset from one position to another, if the unit is known or every cluster between is
    /// a single code unit (both units then count alike).
    private func hostOffset(from start: Int, to end: Int) -> Int? {
        guard start != end else { return 0 }
        if unit == .grapheme { return end - start }
        let units = navigator.utf16Distance(from: start, to: end)
        if unit == .utf16 || abs(units) == abs(end - start) { return units }
        return nil
    }

    // MARK: Host

    private mutating func nextAdjustment(timestamp: TimeInterval, context: Context) -> Int? {
        let target = navigator.cursor
        guard flight == nil, committed != target else { return nil }
        let direction = target > committed ? 1 : -1
        if let unit {
            let offset = unit == .utf16 ? navigator.utf16Distance(from: committed, to: target) : target - committed
            committed = target
            flight = (.move, timestamp, context)
            return offset
        }
        // Until the unit is known, move only across single-code-unit characters, which both count alike.
        var reach = committed
        while reach != target, abs(navigator.utf16Distance(from: reach, to: reach + direction)) == 1 {
            reach += direction
        }
        if reach != committed {
            let offset = reach - committed
            committed = reach
            flight = (.move, timestamp, context)
            return offset
        }
        let step = probeStep(from: committed, direction: direction)
        flight = (.unitProbe(from: committed, direction: direction, step: step), timestamp, context)
        return direction * step
    }

    /// The host is caught up. Re-snapshots when the caret is near the snapshot's edge and the host
    /// shows more, and reaches for the line beyond the snapshot when the point is on it.
    private mutating func extendSnapshot(_ context: Context, timestamp: TimeInterval) -> Int? {
        let knownBefore = navigator.boundaries[committed]
        let knownAfter = navigator.units.count - knownBefore
        let hostBefore = context.before.utf16.count
        let hostAfter = context.after.utf16.count
        if let edge = blocked, !isSoftEdge(edge) {
            let hostShowsMore = edge == .end ? hostAfter > knownAfter : hostBefore > knownBefore
            if hostShowsMore {
                resnapshot(context)
                retarget()
                return nextAdjustment(timestamp: timestamp, context: context)
            }
            // One jump just past the snapshot's edge, from where the caret is. A host ignores an offset
            // past the document's edge, so at the first or last line nothing visibly moves.
            let edgePosition = edge == .end ? navigator.lastPosition : 0
            guard let distance = hostOffset(from: committed, to: edgePosition) else {
                // The unit is still unknown across multi-unit text: walk to the edge first.
                navigator.setCursor(edgePosition)
                return nextAdjustment(timestamp: timestamp, context: context)
            }
            blocked = nil
            flight = (.edgeProbe(edge), timestamp, context)
            return distance + (edge == .end ? 1 : -1)
        }
        // The caret reached a line whose start the snapshot does not show, coming from one it does.
        // When the host now shows more before it, re-snapshot and keep the point's real column.
        if xIsReal, navigator.line(of: committed, in: lines) < firstAnchoredLine, hostBefore > knownBefore {
            resnapshot(context, keepingColumn: true)
            retarget()
            return nextAdjustment(timestamp: timestamp, context: context)
        }
        let margin = parameters.resnapshotMargin
        let nearEnd = navigator.lastPosition - committed <= margin && hostAfter > knownAfter
        let nearStart = committed <= margin && hostBefore > knownBefore
        guard nearEnd || nearStart else { return nil }
        resnapshot(context)
        retarget()
        return nextAdjustment(timestamp: timestamp, context: context)
    }

    /// After a probe with no usable answer: the host's context becomes the snapshot and the point moves
    /// onto the caret, so the caret stays until the finger moves again.
    private mutating func resnapshotAtCaret(_ context: Context) {
        resnapshot(context)
        let line = navigator.line(of: committed, in: lines)
        point.place(x: navigator.x(of: committed, lines: lines, layout: layout), y: center(line))
        xIsReal = line >= firstAnchoredLine
        retarget()
    }

    /// Takes the host's context as the new snapshot and re-anchors the point: the vertical offset from
    /// the caret's line is kept, less the lines the caret crossed to get here. The snapshot may start
    /// mid-paragraph, where its x coordinates are not real columns, so on the same line the point keeps
    /// its offset from the caret; after crossing a line, or when asked, x is kept as the column.
    private mutating func resnapshot(_ context: Context, linesCrossed: Int = 0, keepingColumn: Bool = false) {
        let oldLine = navigator.line(of: committed, in: lines)
        let offset = point.y - center(oldLine)
        let columnOffset = point.x - navigator.x(of: committed, lines: lines, layout: layout)
        // Ambiguity is counted only while nothing changes.
        if context != snapshotContext { ambiguousProbes = [:] }
        snapshotContext = context
        navigator = TextNavigator(before: context.before, after: context.after)
        committed = navigator.cursor
        lines = layout.lines(in: navigator.text)
        firstAnchoredLine = Self.firstAnchoredLine(navigator.text, lines: lines, startsLine: context.startsLine)
        let line = navigator.line(of: committed, in: lines)
        let keepsColumn = linesCrossed != 0 || keepingColumn
        let x = keepsColumn ? point.x : navigator.x(of: committed, lines: lines, layout: layout) + columnOffset
        if !keepsColumn { xIsReal = line >= firstAnchoredLine }
        point.place(x: x, y: center(line) + offset - Double(linesCrossed) * lineHeight)
    }
}
