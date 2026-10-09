import Foundation

/// One trackpad gesture over the text the proxy exposes. The keyboard feeds it touch samples and,
/// once per display frame, what the proxy reports; it answers with at most one offset to pass to
/// `adjustTextPosition(byCharacterOffset:)`. Pure, so the loop is tested against a simulated host.
///
/// The proxy shows only a window of text around the caret (in UIKit, about a sentence before and
/// the rest of the sentence after, stopping at line breaks), and its context updates after an
/// adjustment either at once or a little later. So the cursor moves virtually inside a snapshot
/// and the host is told where it went, in its own unit, once per frame. The snapshot is refreshed
/// when the cursor nears its edge and the host has caught up. A hidden line break is crossed by a
/// single-unit step, and a step the host ignores marks the document's start or end.
struct TrackpadSession {
    struct Context: Equatable {
        var before: String
        var after: String
    }

    enum Edge: Hashable { case start, end }

    private enum Axis { case horizontal, vertical }

    private struct Blocked {
        var edge: Edge
        var axis: Axis
    }

    private enum Flight {
        case move
        /// One code unit into a multi-unit cluster: UIKit stops inside it, WebKit crosses it.
        case unitProbe(from: Int, direction: Int)
        /// One step past the visible text, usually across a line break.
        case edgeProbe(Edge, Axis)
    }

    let parameters: TrackpadParameters
    /// Learned from the host on the first multi-unit cluster; the keyboard keeps it per document.
    private(set) var unit: CursorOffsetUnit?
    private(set) var navigator: TextNavigator
    /// Where the host's caret is, or will be once the adjustment in flight lands.
    private(set) var committed: Int
    private(set) var motion: CursorMotion
    private(set) var confirmedEdges: Set<Edge> = []
    private let layout: any LineLayout
    private let advance: (String) -> Double
    private let lineHeight: Double
    private var lines: [Range<Int>]
    /// The column kept across vertical moves, in points, like a text editor's goal column.
    private var goalX: Double?
    private var pendingLines = 0
    private var blocked: Blocked?
    /// The cursor reached a line whose text the proxy has not shown yet (in UIKit, right after a
    /// line break the context is just "\n"); place it at the goal column once it has.
    private var needsColumnSnap = false
    private var flight: (kind: Flight, issuedAt: TimeInterval, context: Context)?
    private var endedAt: TimeInterval?

    init(before: String?, after: String?, unit: CursorOffsetUnit?, parameters: TrackpadParameters,
         layout: any LineLayout, lineHeight: Double, advance: @escaping (String) -> Double) {
        self.parameters = parameters
        self.unit = unit
        self.layout = layout
        self.lineHeight = lineHeight
        self.advance = advance
        navigator = TextNavigator(before: before ?? "", after: after ?? "")
        committed = navigator.cursor
        motion = CursorMotion(parameters: parameters)
        lines = layout.lines(in: navigator.text)
    }

    /// Nothing is in flight and the host has been told where the cursor is.
    var isSettled: Bool { flight == nil && committed == navigator.cursor }

    var isEnded: Bool { endedAt != nil }

    /// After the finger lifts: settled, or out of time to finish.
    func isFinished(at timestamp: TimeInterval) -> Bool {
        guard let endedAt else { return false }
        return isSettled || timestamp - endedAt >= parameters.settleTimeout
    }

    mutating func drag(dx: Double, dy: Double, timestamp: TimeInterval) {
        guard endedAt == nil else { return }
        motion.add(dx: dx, dy: dy, timestamp: timestamp)
        applyMotion()
    }

    /// The finger lifted: pending adjustments still land, but nothing new starts.
    mutating func end(at timestamp: TimeInterval) {
        guard endedAt == nil else { return }
        endedAt = timestamp
        blocked = nil
        pendingLines = 0
    }

    /// Call once per display frame with the proxy's current context. Returns the offset to pass to
    /// `adjustTextPosition`, if any.
    mutating func frame(before: String?, after: String?, timestamp: TimeInterval) -> Int? {
        let context = Context(before: before ?? "", after: after ?? "")
        if let flight {
            let timedOut = timestamp - flight.issuedAt >= parameters.syncTimeout
            switch flight.kind {
            case .move:
                if navigator.agrees(before: context.before, after: context.after, at: committed)
                    // Nothing to compare, but the host moved: take it as landed and re-snapshot.
                    || (!navigator.canCompare(before: context.before, after: context.after, at: committed)
                        && context != flight.context) {
                    self.flight = nil
                } else if timedOut {
                    // The host did something else; trust what it reports.
                    self.flight = nil
                    resnapshot(context)
                    applyMotion()
                } else {
                    return nil
                }
            case .unitProbe(let from, let direction):
                let beyond = from + direction
                if navigator.agrees(before: context.before, after: context.after, at: beyond) {
                    unit = .grapheme
                    committed = beyond
                    self.flight = nil
                } else if context != flight.context {
                    // UIKit stopped one code unit into the cluster; finish crossing it.
                    unit = .utf16
                    committed = beyond
                    self.flight = (.move, timestamp, context)
                    return direction * (abs(navigator.utf16Distance(from: from, to: beyond)) - 1)
                } else if timedOut {
                    self.flight = nil
                    resnapshot(context)
                    applyMotion()
                } else {
                    return nil
                }
            case .edgeProbe(let edge, let axis):
                if context != flight.context {
                    self.flight = nil
                    resnapshot(context)
                    crossedHiddenBoundary(at: edge, axis: axis)
                } else if timedOut {
                    // The host ignored the step: this is the document's start or end.
                    self.flight = nil
                    confirmedEdges.insert(edge)
                    stop(axis, at: edge)
                } else {
                    return nil
                }
            }
        }
        if let offset = nextAdjustment(timestamp: timestamp, context: context) { return offset }
        guard endedAt == nil else { return nil }
        return extendSnapshot(context, timestamp: timestamp)
    }

    // MARK: Motion

    private mutating func applyMotion() {
        guard endedAt == nil else { return }
        blocked = nil
        pendingLines += motion.takeLineSteps(lineHeight: lineHeight)
        guard !needsColumnSnap else { return }
        while pendingLines != 0 {
            let direction = pendingLines > 0 ? 1 : -1
            let edge: Edge = direction > 0 ? .end : .start
            let goal = goalX ?? navigator.x(of: navigator.cursor, lines: lines, layout: layout)
            goalX = goal
            let target = navigator.line(of: navigator.cursor, in: lines) + direction
            if target == 0, direction < 0, startsWithUnseenLine {
                // The end of the line above is all that is known of it.
                navigator.setCursor(0)
                pendingLines -= direction
                needsColumnSnap = true
                return
            } else if lines.indices.contains(target) {
                navigator.setCursor(navigator.position(nearestX: goal, onLine: target, lines: lines, layout: layout))
                pendingLines -= direction
            } else if confirmedEdges.contains(edge) {
                stop(.vertical, at: edge)
            } else {
                // Go to the end of the known text on this line, and wait for the proxy to show more.
                navigator.setCursor(edge == .end ? navigator.lastPosition : 0)
                blocked = Blocked(edge: edge, axis: .vertical)
                return
            }
        }
        let cursor = navigator.cursor
        let result = motion.takeHorizontalSteps { [navigator, parameters, advance] k in
            guard let grapheme = navigator.grapheme(after: cursor + k) else { return nil }
            return grapheme.first?.isNewline == true ? parameters.fallbackAdvance : advance(grapheme)
        }
        if result.steps != 0 {
            navigator.setCursor(cursor + result.steps)
            goalX = nil
        }
        // On a document edge the pointer cannot pass it at all, so reversing responds at once.
        if navigator.cursor == navigator.lastPosition, confirmedEdges.contains(.end) {
            motion.stopHorizontal(atEnd: true)
        } else if navigator.cursor == 0, confirmedEdges.contains(.start) {
            motion.stopHorizontal(atEnd: false)
        } else if result.blockedForward || result.blockedBackward {
            let edge: Edge = result.blockedForward ? .end : .start
            if confirmedEdges.contains(edge) {
                stop(.horizontal, at: edge)
            } else {
                blocked = Blocked(edge: edge, axis: .horizontal)
                motion.limitHorizontal(to: parameters.maximumPendingTravel)
            }
        }
    }

    /// The snapshot opens with a line break whose line the proxy did not show.
    private var startsWithUnseenLine: Bool {
        lines.first.map { $0.lowerBound == 0 && $0.upperBound == navigator.boundaries[min(1, navigator.lastPosition)] } == true
            && navigator.grapheme(after: 0)?.first?.isNewline == true
    }

    private mutating func stop(_ axis: Axis, at edge: Edge) {
        switch axis {
        case .horizontal:
            motion.stopHorizontal(atEnd: edge == .end)
        case .vertical:
            pendingLines = 0
            motion.stopVertical()
        }
        blocked = nil
    }

    /// An edge probe moved the caret one character past the text the proxy showed.
    private mutating func crossedHiddenBoundary(at edge: Edge, axis: Axis) {
        let direction = edge == .end ? 1 : -1
        switch axis {
        case .horizontal:
            motion.consumeHorizontal(Double(direction) * parameters.fallbackAdvance)
        case .vertical:
            // Across a line break the caret is now on the adjacent line; place it at the column.
            pendingLines -= direction
            if let goalX {
                let line = navigator.line(of: navigator.cursor, in: lines)
                navigator.setCursor(navigator.position(nearestX: goalX, onLine: line, lines: lines, layout: layout))
            }
        }
        applyMotion()
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
        flight = (.unitProbe(from: committed, direction: direction), timestamp, context)
        return direction
    }

    /// The host is caught up and the cursor is near or at the snapshot's edge.
    private mutating func extendSnapshot(_ context: Context, timestamp: TimeInterval) -> Int? {
        let knownBefore = navigator.boundaries[navigator.cursor]
        let knownAfter = navigator.units.count - knownBefore
        let hostBefore = context.before.utf16.count
        let hostAfter = context.after.utf16.count
        if needsColumnSnap {
            needsColumnSnap = false
            if hostBefore > knownBefore {
                resnapshot(context)
                if let goalX {
                    let line = navigator.line(of: navigator.cursor, in: lines)
                    navigator.setCursor(navigator.position(nearestX: goalX, onLine: line, lines: lines, layout: layout))
                }
            }
            applyMotion()
            return nextAdjustment(timestamp: timestamp, context: context)
        }
        if let blocked {
            let hostShowsMore = blocked.edge == .end ? hostAfter > knownAfter : hostBefore > knownBefore
            if hostShowsMore {
                resnapshot(context)
                applyMotion()
                return nextAdjustment(timestamp: timestamp, context: context)
            }
            // The proxy shows nothing further that way; step across the hidden boundary.
            self.blocked = nil
            flight = (.edgeProbe(blocked.edge, blocked.axis), timestamp, context)
            return blocked.edge == .end ? 1 : -1
        }
        let margin = parameters.resnapshotMargin
        let nearEnd = navigator.lastPosition - navigator.cursor <= margin && hostAfter > knownAfter
        let nearStart = navigator.cursor <= margin && hostBefore > knownBefore
        guard nearEnd || nearStart else { return nil }
        resnapshot(context)
        applyMotion()
        return nextAdjustment(timestamp: timestamp, context: context)
    }

    private mutating func resnapshot(_ context: Context) {
        navigator = TextNavigator(before: context.before, after: context.after)
        committed = navigator.cursor
        lines = layout.lines(in: navigator.text)
        // An edge was proven at the old snapshot's end; the new one may end elsewhere.
        confirmedEdges = []
    }
}
