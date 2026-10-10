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
/// The point is the intended target and is kept apart from how the caret gets there (probes, a
/// walk to the snapshot's edge, refreshed snapshots). After the finger lifts the point stays where it
/// was, and settling keeps re-anchoring and snapping it until the caret is there.
///
/// Safety rules (ARCHITECTURE.md, "Trackpad safety", "Undo ownership v2", "Probes only where units
/// can differ"):
/// - Moves across single-code-point BMP characters need no probe: both units count them alike.
///   Only crossing a multi-unit cluster with the unit unknown probes, by the cluster's UTF-16 length
///   (or the crossing-side scalar when the snapshot has too few clusters, never mid-pair).
/// - Each adjustment carries a consumable expectation: where it should leave the caret. A host
///   callback counts as the gesture's own only if it matches one (`acknowledge`); anything else is
///   an outside change, and the keyboard ends the gesture. There are no time windows.
/// - A probe is read only once its callback matched, or after the timeout: the proxy's immediate
///   answer is provisional. Its outcome is placed through overlapping local anchors; the unit is
///   learned only when exactly one unit explains it. An outcome inside a cluster is completed (or,
///   after cancellation, rolled back) to a real boundary; one that cannot be placed is rolled back
///   to where the probe started. A caret left inside a cluster is always repaired.
/// - A context that shows the caret exactly at the snapshot's edge is never read as a crossing. An
///   unchanged context after an edge probe is ambiguous (an ignored step at the document's edge looks
///   like a move between blank lines), never a boundary. Further probes need new finger travel;
///   after `maximumAmbiguousProbes` the edge holds, and new travel past it allows one more at a time.
/// - Probes whose outcome could not be placed are retried at most `automaticProbeRetries` times
///   without new finger travel. A probe the host verifiably ignored (a grapheme host asked to step
///   past the text) is retried with the smallest step.
/// - Outcomes with unknowns (a jump past the snapshot's edge) need affirmative evidence: an emptied
///   field matches nothing. A `selectionDidChange` fits only an adjustment still owed a callback.
/// - Cancellation (and hiding) drops the snapshot and every expected context at once, rolls an
///   outstanding probe back, and watches an outstanding jump past the edge until its time limit,
///   moving a caret it left inside a hidden cluster back to the cluster's edge.
/// The keyboard re-validates the field and the edit generation before every adjustment.
struct TrackpadSession {
    struct Context: Equatable {
        var before: String
        var after: String
        /// The text starts a line: the host showed the line break before it, or nothing at all (the
        /// document's start).
        var startsLine = false
        /// The host showed a line break first, which the session drops from `before`.
        var droppedLineBreak = false
    }

    enum Edge: Hashable { case start, end }

    private enum Flight: Equatable {
        /// To `committed`, a caret position of the snapshot, from UTF-16 offset `from` of the snapshot (nil:
        /// unknown, so only its callback or the timeout lands it).
        case move(from: Int?)
        /// `step` units across the cluster after `from` (before it, for `direction` -1).
        case unitProbe(from: Int, direction: Int, step: Int)
        /// A jump just past the snapshot's edge, to reveal the line beyond it, by `offset`.
        case edgeProbe(Edge, offset: Int)
        /// From inside a cluster to its edge; `target` is that edge's position, unless the snapshot
        /// could not show the cluster (a split surrogate pair reads as two U+FFFD).
        case repair(target: Int?)
    }

    private struct InFlight {
        var kind: Flight
        var issuedAt: TimeInterval
        var context: Context
        var expectation: Int
        /// A host callback matched this adjustment's expectation.
        var acknowledged = false
    }

    /// An issued adjustment whose callback has not arrived: the contexts it may leave.
    private struct Pending {
        var id: Int
        var outcomes: [CaretExpectation]
        /// The context it was issued in. WebKit reports every adjustment twice, first with this context
        /// (the proxy shows it again until the second report; measured in a WKWebView, round 6).
        var issuedIn: Context
        var reportedAsIssued = false
    }

    private(set) var parameters: TrackpadParameters
    /// Known from an earlier gesture in this field, or learned from discriminating evidence.
    private(set) var unit: CursorOffsetUnit?
    private(set) var navigator: TextNavigator
    /// Where the host's caret is, or will be once the adjustment in flight lands.
    private(set) var committed: Int
    /// The floating point, in the snapshot's layout: the intended target.
    private(set) var point: FloatingCursor
    /// Edge probes at each edge whose outcome was ambiguous since the context last changed.
    private(set) var ambiguousProbes: [Edge: Int] = [:]
    private(set) var isCancelled = false
    /// A cancelled jump past the snapshot's edge whose outcome is not known yet: it may stop inside a
    /// cluster the snapshot never showed (a UTF-16 host one unit into "👍🏽"). Until its time is up, a
    /// caret the context shows inside a cluster is moved back to the cluster's edge on the side the
    /// jump came from. Holds no text: the direction, the deadline, and a hash of the context the last
    /// repair was issued in (so a repair is not repeated before the host shows its result).
    private var edgeWatch: (direction: Int, deadline: TimeInterval, repairs: Int, repairedIn: String?)?
    /// A probe the host verifiably ignored (a grapheme host asked to step past the text): the next
    /// probe from there takes the smallest step.
    private var ignoredProbe: (from: Int, direction: Int)?
    /// Probes whose outcome could not be placed may still be retried this many times.
    private(set) var retriesLeft: Int
    /// The next step needs a probe, and none may run until the finger moves on.
    private(set) var isStalled = false
    private let layout: any LineLayout
    /// The host's line advance (lineHeight + leading): lines are this far apart, so the point snaps
    /// to the next line half of it past a line's center.
    private let linePitch: Double
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
    /// A position the caret must reach first (the snapshot's edge, walked to before a jump past it);
    /// the target itself stays where the point is.
    private var waypoint: Int?
    /// The adopted context leaves the caret inside a cluster.
    private var needsRepair = false
    private var repairs = 0
    /// Finger travel since probes stalled, and past each held edge.
    private var retryTravel = 0.0
    private var edgeTravel: [Edge: Double] = [:]
    /// The direction of the last move toward the target, for repairs.
    private var travelDirection = 1
    private var flight: InFlight?
    private var pending: [Pending] = []
    private var lastConsumed: [CaretExpectation] = []
    /// Whether the host reports each adjustment twice, first as issued (WebKit), or once (UIKit); nil
    /// until a moved adjustment has shown which. Until then, a report that shows an adjustment ignored
    /// waits for a second report or the timeout.
    private(set) var reportsTwice: Bool?
    /// Callbacks the issued adjustments may still cause: one each.
    private(set) var unconfirmedAdjustments = 0
    private var nextExpectation = 1
    private var endedAt: TimeInterval?
    private var lastIssuedAt: TimeInterval?

    /// `reportsTwice`: how the host reports adjustments, if an earlier gesture in this field learned it.
    init(before: String?, after: String?, unit: CursorOffsetUnit?, reportsTwice: Bool? = nil,
         parameters: TrackpadParameters, layout: any LineLayout, linePitch: Double, layoutWidth: Double) {
        self.parameters = parameters
        self.unit = unit
        self.reportsTwice = reportsTwice
        self.layout = layout
        self.linePitch = max(linePitch, 1)
        self.layoutWidth = max(layoutWidth, parameters.leftInset + parameters.rightInset + 1)
        retriesLeft = parameters.automaticProbeRetries
        snapshotContext = Self.visible(before: before, after: after)
        navigator = TextNavigator(before: snapshotContext.before, after: snapshotContext.after)
        committed = navigator.cursor
        lines = layout.lines(in: navigator.text)
        let line = navigator.line(of: navigator.cursor, in: lines)
        // The point starts exactly at the caret.
        point = FloatingCursor(parameters: parameters, x: navigator.x(of: navigator.cursor, lines: lines, layout: layout),
                               y: (Double(line) + 0.5) * max(linePitch, 1))
        firstAnchoredLine = Self.firstAnchoredLine(navigator.text, lines: lines, startsLine: snapshotContext.startsLine)
        xIsReal = line >= firstAnchoredLine
        // Only a host that counts UTF-16 units leaves the caret inside a cluster.
        if navigator.snapshotSplit != nil || Self.splitsSurrogatePair(snapshotContext) { self.unit = .utf16 }
    }

    /// Nothing is in flight, and the caret is at the target or can get no closer for now.
    var isSettled: Bool {
        // A cancelled gesture issues nothing more than a rollback; its last adjustment only has to be
        // heard from.
        if isCancelled { return edgeWatch == nil }
        guard flight == nil, !needsRepair else { return false }
        if isStalled { return true }
        if committed != (waypoint ?? navigator.cursor) { return false }
        if let edge = blocked, !isSoftEdge(edge) { return false }
        return true
    }

    var isEnded: Bool { endedAt != nil }

    /// A unit probe is outstanding: the caret may be past or inside a cluster until it is resolved.
    var hasOutstandingProbe: Bool {
        if case .unitProbe? = flight?.kind { return true }
        return false
    }

    func isSoftEdge(_ edge: Edge) -> Bool {
        ambiguousProbes[edge, default: 0] >= parameters.maximumAmbiguousProbes
    }

    /// After the finger lifts: settled and its callbacks seen (or overdue), or out of time to finish.
    /// Each adjustment issued after the lift gets its own time to land.
    func isFinished(at timestamp: TimeInterval) -> Bool {
        guard let endedAt else { return false }
        let lastActivity = max(endedAt, lastIssuedAt ?? endedAt)
        if timestamp - lastActivity >= parameters.settleTimeout { return true }
        guard isSettled else { return false }
        return unconfirmedAdjustments == 0 || timestamp - lastActivity >= parameters.syncTimeout
    }

    /// The touch rate changed (`TouchRateEstimator`); applies to the next touch events.
    mutating func setEventStepScale(_ scale: Double) {
        guard scale.isFinite, scale > 0 else { return }
        parameters.eventStepScale = scale
        point.parameters.eventStepScale = scale
    }

    /// One delivered touch event's finger movement. The point moves at once; the caret follows.
    mutating func drag(dx: Double, dy: Double) {
        guard endedAt == nil else { return }
        let moved = point.move(dx: dx, dy: dy)
        let distance = (moved.dx * moved.dx + moved.dy * moved.dy).squareRoot()
        if distance > 0, retriesLeft <= 0 {
            // New finger travel allows another probe.
            retryTravel += distance
            if retryTravel >= parameters.probeTravelLines * linePitch {
                retryTravel = 0
                retriesLeft = 1
                isStalled = false
            }
        }
        retarget()
    }

    /// The finger lifted: the target stays where the point is, and settling continues toward it.
    mutating func end(at timestamp: TimeInterval) {
        guard endedAt == nil else { return }
        endedAt = timestamp
    }

    /// The system cancelled the gesture, or the keyboard is hiding: stop where the host is, and drop
    /// the snapshot and every expected context at once. An outstanding unit probe is rolled back now
    /// (the same count back returns to where it started, in either unit); the returned offset must be
    /// issued now. A jump past the snapshot's edge whose outcome is unknown is watched until its time
    /// limit: a caret it leaves inside a hidden cluster is moved back to the cluster's edge
    /// (`resolveEdgeWatch`). Nothing else follows.
    mutating func cancel(at timestamp: TimeInterval) -> Int? {
        end(at: timestamp)
        guard !isCancelled else { return nil }
        isCancelled = true
        waypoint = nil
        needsRepair = false
        blocked = nil
        var rollback: Int?
        if let current = flight {
            switch current.kind {
            case .unitProbe(let from, let direction, let step):
                committed = from
                rollback = launch(.move(from: nil), offset: -direction * step, outcomes: [], context: current.context,
                                  at: timestamp)
            case .edgeProbe(_, let offset):
                edgeWatch = (offset > 0 ? 1 : -1, current.issuedAt + parameters.syncTimeout, 0, nil)
                flight = nil
            case .move, .repair:
                break
            }
        }
        forgetContext()
        return rollback
    }

    /// A hash of a context, to tell later whether it changed without keeping its text.
    private static func contextHash(_ context: Context) -> String {
        FieldFingerprint.hash(context.before + "\u{0}" + context.after)
    }

    /// Drops every copy of the field's text this session holds.
    private mutating func forgetContext() {
        snapshotContext = Context(before: "", after: "")
        navigator = TextNavigator(before: "", after: "")
        lines = [0 ..< 0]
        committed = 0
        pending = []
        lastConsumed = []
        if var current = flight {
            current.context = Context(before: "", after: "")
            flight = current
        }
    }

    /// A cancelled gesture's jump past the snapshot's edge: if the context shows the caret inside a
    /// cluster, back to the cluster's edge on the side the jump came from (UTF-16 units: no other host
    /// stops there), at most `maximumRepairs` times. Wherever else the caret is (the jump ignored, a line
    /// crossed, the user moved it), it stays. Done once the time is up with the caret on a boundary.
    private mutating func resolveEdgeWatch(_ context: Context, timestamp: TimeInterval) -> Int? {
        guard var watch = edgeWatch else { return nil }
        let split: (back: Int, forward: Int)? = Self.splitsSurrogatePair(context)
            ? (1, 1) : TextNavigator(before: context.before, after: context.after).snapshotSplit
        let hash = Self.contextHash(context)
        if let split, watch.repairs < parameters.maximumRepairs, hash != watch.repairedIn {
            watch.repairs += 1
            watch.repairedIn = hash
            edgeWatch = watch
            return launch(.move(from: nil), offset: watch.direction > 0 ? -split.back : split.forward, outcomes: [],
                          context: Context(before: "", after: ""), at: timestamp)
        }
        if (split == nil && timestamp >= watch.deadline) || watch.repairs >= parameters.maximumRepairs { edgeWatch = nil }
        return nil
    }

    /// Call once per display frame with the proxy's current context. Returns the offset to pass to
    /// `adjustTextPosition`, if any.
    mutating func frame(before: String?, after: String?, timestamp: TimeInterval) -> Int? {
        let context = Self.visible(before: before, after: after)
        guard !isCancelled else { return resolveEdgeWatch(context, timestamp: timestamp) }
        if let current = flight {
            let timedOut = timestamp - current.issuedAt >= parameters.syncTimeout
            let fresh = context != current.context
            switch current.kind {
            case .move(let from):
                // Agreement lands the move only if it tells the two ends apart: in repetitive text a narrow
                // window can fit where the caret was as well as where it goes. Then wait for the callback.
                let arrived = navigator.agrees(before: context.before, after: context.after, at: committed)
                let distinct = from.map {
                    $0 == navigator.boundaries[committed]
                        || !navigator.agrees(before: context.before, after: context.after, atUTF16: $0)
                } ?? false
                if (arrived && (distinct || current.acknowledged))
                    // Nothing to compare, but the host moved and confirmed it: take it as landed.
                    || (fresh && current.acknowledged
                        && !navigator.canCompare(before: context.before, after: context.after, at: committed)) {
                    flight = nil
                } else if timedOut {
                    // The host did something else; trust what it reports.
                    flight = nil
                    adopt(context)
                } else {
                    return nil
                }
            case .repair(let target):
                if let target, navigator.agrees(before: context.before, after: context.after, at: target) {
                    flight = nil
                    repairs = 0
                } else if (fresh && current.acknowledged) || timedOut {
                    flight = nil
                    adopt(context)
                } else {
                    return nil
                }
            case .unitProbe(let from, let direction, let step):
                guard current.acknowledged || timedOut else { return nil }
                flight = nil
                if fresh {
                    if let offset = resolveProbe(from: from, direction: direction, step: step, context: context,
                                                 timestamp: timestamp) {
                        return offset
                    }
                } else {
                    // The host confirmed, or let the time pass, with the context as it was: it ignored the
                    // step (a grapheme host asked to step past the text). Learn nothing; the target stays,
                    // the next probe from here takes the smallest step, and the budget bounds retries.
                    probeIgnored(from: from, direction: direction, context: context)
                }
            case .edgeProbe(let edge, _):
                // The caret at the snapshot's edge, not past it, is the proxy's provisional answer (or a
                // host that clamps instead of ignoring): no line was crossed.
                let crossed = fresh && !showsCaretAtEdge(edge, context)
                if crossed && (current.acknowledged || timedOut) {
                    // The caret crossed into text the snapshot did not show: one line toward the point.
                    flight = nil
                    adopt(context, linesCrossed: edge == .end ? 1 : -1)
                } else if timedOut || (current.acknowledged && !fresh) {
                    // Unchanged, or still the provisional edge: the host ignored the jump (measured at
                    // the document's edge) and the caret is where it was.
                    flight = nil
                    ambiguousStep(at: edge)
                } else {
                    return nil
                }
            }
        }
        return advance(context, timestamp: timestamp)
    }
    /// The host's `textDidChange` for one of this session's adjustments. Returns false for an outside
    /// change: a context that is none of the following.
    /// - **As issued:** exactly the context an adjustment owed a callback was issued in, once per
    ///   adjustment and never empty. WebKit reports every adjustment twice, first this way (measured in
    ///   a WKWebView, round 6). It confirms nothing. Once the host is known to report once (a moved
    ///   adjustment reported only as it landed), such a report is an adjustment the host ignored.
    /// - **As landed:** an expected outcome of an adjustment owed a callback. Consumes it, and every
    ///   older one (a host may report several adjustments at once), and confirms the adjustment.
    /// - **Again:** the state last confirmed, for each callback still owed beyond the adjustments
    ///   pending (a host that reported several at once).
    mutating func acknowledge(before: String?, after: String?) -> Bool {
        let context = Self.visible(before: before, after: after)
        if isCancelled {
            // A cancelled gesture holds no expected text any more; what it still owes callbacks for are
            // its rollback and repairs, which only ever move the caret back onto a boundary.
            guard unconfirmedAdjustments > 0 else { return false }
            unconfirmedAdjustments -= 1
            return true
        }
        guard unconfirmedAdjustments > 0 else { return false }
        if reportsTwice != false, !context.before.isEmpty || !context.after.isEmpty,
           let index = pending.firstIndex(where: { !$0.reportedAsIssued && $0.issuedIn == context }) {
            pending[index].reportedAsIssued = true
            return true
        }
        if let index = pending.firstIndex(where: { Self.fits(context, $0.outcomes) }) {
            let entry = pending[index]
            if context != entry.issuedIn, reportsTwice == nil {
                // A moved adjustment: reported first as issued, or only as it landed.
                reportsTwice = entry.reportedAsIssued
            }
            pending.removeFirst(index + 1)
            lastConsumed = entry.outcomes
            unconfirmedAdjustments -= 1
            if var current = flight, current.expectation <= entry.id {
                current.acknowledged = true
                flight = current
            }
            return true
        }
        if unconfirmedAdjustments > pending.count, Self.fits(context, lastConsumed) {
            unconfirmedAdjustments -= 1
            return true
        }
        return false
    }

    /// Whether another host callback (`selectionDidChange`) fits this session: only an expected outcome
    /// of an adjustment still owed a callback. Consumes nothing. Anything else (the caret where it
    /// already was included) is an outside change.
    func fits(before: String?, after: String?) -> Bool {
        let context = Self.visible(before: before, after: after)
        return unconfirmedAdjustments > 0 && pending.contains { Self.fits(context, $0.outcomes) }
    }

    /// Expectations are matched against the host's own text, the line break the session drops included:
    /// it is the evidence of a jump past the snapshot's end onto a blank line.
    private static func fits(_ context: Context, _ outcomes: [CaretExpectation]) -> Bool {
        let before = context.droppedLineBreak ? "\n" + context.before : context.before
        return outcomes.contains { $0.matches(before: before, after: context.after) }
    }

    /// Records an adjustment and its expected outcomes, and returns its offset.
    private mutating func launch(_ kind: Flight, offset: Int, outcomes: [CaretExpectation], context: Context,
                                 at timestamp: TimeInterval) -> Int {
        let id = nextExpectation
        nextExpectation += 1
        pending.append(Pending(id: id, outcomes: outcomes, issuedIn: context))
        if pending.count > 16 { pending.removeFirst(pending.count - 16) }
        unconfirmedAdjustments += 1
        flight = InFlight(kind: kind, issuedAt: timestamp, context: context, expectation: id)
        lastIssuedAt = timestamp
        return offset
    }

    /// The context as the session reads it. A before-context that starts with a line break ends a
    /// line whose text is hidden; the break is dropped, so the snapshot's first line is a real one and
    /// reaching the line above takes an edge probe.
    private static func visible(before: String?, after: String?) -> Context {
        var before = before ?? ""
        let startsLine = before.isEmpty || before.first?.isNewline == true
        let droppedLineBreak = before.first?.isNewline == true
        if droppedLineBreak { before.removeFirst() }
        return Context(before: before, after: after ?? "", startsLine: startsLine, droppedLineBreak: droppedLineBreak)
    }

    /// A caret between the halves of a surrogate pair: Swift shows each half as U+FFFD.
    private static func splitsSurrogatePair(_ context: Context) -> Bool {
        context.before.unicodeScalars.last == "\u{FFFD}" && context.after.unicodeScalars.first == "\u{FFFD}"
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

    private func center(_ line: Int) -> Double { (Double(line) + 0.5) * linePitch }

    /// Clamps the point and sends the target to the boundary nearest it. Also after the lift: a new
    /// snapshot re-anchors the point, and the target is snapped again.
    private mutating func retarget() {
        guard !isCancelled, !lines.isEmpty else { return }
        let last = lines.count - 1
        let reach = parameters.pendingLines * linePitch
        let top = isSoftEdge(.start) ? center(0) - parameters.topOvershoot : center(0) - reach
        let bottom = isSoftEdge(.end) ? center(last) + parameters.bottomOvershoot : center(last) + reach
        // New finger travel past a held edge allows one more probe there.
        if isSoftEdge(.end), point.y > bottom { creditTravel(point.y - bottom, at: .end) }
        if isSoftEdge(.start), point.y < top { creditTravel(top - point.y, at: .start) }
        point.clamp(x: parameters.leftInset ... layoutWidth - parameters.rightInset, y: top ... bottom)
        // The line whose center is nearest the point.
        let ideal = Int((point.y / linePitch).rounded(.down))
        blocked = ideal < 0 ? .start : (ideal > last ? .end : nil)
        let line = min(max(ideal, 0), last)
        navigator.setCursor(navigator.position(nearestX: point.x, onLine: line, lines: lines, layout: layout))
    }

    private mutating func creditTravel(_ distance: Double, at edge: Edge) {
        edgeTravel[edge, default: 0] += distance
        guard edgeTravel[edge, default: 0] >= parameters.probeTravelLines * linePitch else { return }
        edgeTravel[edge] = 0
        ambiguousProbes[edge, default: 0] -= 1
    }

    /// An edge probe left the context unchanged: the host ignored it (the document's edge) or moved
    /// between places that look alike (blank lines). Neither is known, so the overshoot is dropped (the
    /// next probe needs new travel); after a bounded number the edge is held like Apple's last line.
    private mutating func ambiguousStep(at edge: Edge) {
        ambiguousProbes[edge, default: 0] += 1
        let last = lines.count - 1
        let margin = 0.45 * linePitch
        let top = edge == .start ? center(0) - min(parameters.topOvershoot, margin) : -Double.greatestFiniteMagnitude
        let bottom = edge == .end ? center(last) + min(parameters.bottomOvershoot, margin) : Double.greatestFiniteMagnitude
        point.clamp(x: -Double.greatestFiniteMagnitude ... Double.greatestFiniteMagnitude, y: top ... bottom)
        retarget()
    }

    // MARK: Units

    /// Places a probe's outcome through overlapping local anchors and returns an offset to issue at
    /// once, if any: the rest of a cluster a UTF-16 host stopped inside (or the way back after
    /// cancellation), or the way back to `from` when the outcome cannot be placed.
    ///
    /// The unit is learned only when exactly one unit explains the outcome: the context fits the caret
    /// where that unit would put it and not where the other would. Repetitive text
    /// ("e\u{301}e\u{301}") can fit several carets; then nothing is learned.
    private mutating func resolveProbe(from: Int, direction: Int, step: Int, context: Context,
                                       timestamp: TimeInterval) -> Int? {
        let utf16Split = navigator.boundaries[from] + direction * step
        let graphemePosition = from + direction * step
        let inside = navigator.boundaries.indices.contains(graphemePosition)
        let utf16Fits = navigator.expectation(atUTF16: utf16Split).matches(before: context.before, after: context.after)
        // A grapheme host never leaves the caret inside a cluster, whatever its hidden side could hold.
        let insideCluster = Self.splitsSurrogatePair(context)
            || TextNavigator(before: context.before, after: context.after).snapshotSplit != nil
        let graphemeFits = !insideCluster && graphemeOutcome(from: from, direction: direction, step: step)
            .matches(before: context.before, after: context.after)
        let stays = navigator.expectation(at: from).matches(before: context.before, after: context.after)
        switch (utf16Fits, graphemeFits, stays) {
        case (false, false, true):
            // Only where the caret was: the host ignored the step, as a grapheme host does when asked to
            // step past the text.
            probeIgnored(from: from, direction: direction, context: context)
            return nil
        case (true, false, false):
            // Only a UTF-16 host puts the caret here (between scalars, or between the halves of a pair).
            unit = .utf16
            return settle(at: utf16Split, from: from, direction: direction, step: step, context: context,
                          timestamp: timestamp)
        case (false, true, false):
            unit = .grapheme
            guard inside else {
                // Past the snapshot's edge by clusters it did not show. Re-snapshot there, keeping the point
                // where it was relative to the text.
                let edge = direction > 0 ? navigator.lastPosition : 0
                committed = edge
                adopt(context, advance: graphemePosition - edge)
                return nil
            }
            committed = graphemePosition
            return nil
        case (false, false, false):
            // Somewhere neither unit predicts: placed only if the context fits exactly one place, and
            // then nothing is learned unless that place is inside a cluster.
            let fits = navigator.locate(before: context.before, after: context.after)
            guard fits.count == 1 else { return rollBack(from: from, direction: direction, step: step, context: context,
                                                         timestamp: timestamp) }
            return settle(at: fits[0], from: from, direction: direction, step: step, context: context,
                          timestamp: timestamp)
        default:
            // The context fits more than one outcome (repetitive text, a narrow window): it teaches
            // nothing, and the probe is rolled back.
            return rollBack(from: from, direction: direction, step: step, context: context, timestamp: timestamp)
        }
    }

    /// The caret is at UTF-16 `located`: a position, or inside a cluster (only a UTF-16 host stops
    /// there), which is completed in the direction of travel. A cancellation rolls the probe back
    /// before its outcome is read.
    private mutating func settle(at located: Int, from: Int, direction: Int, step: Int, context: Context,
                                 timestamp: TimeInterval) -> Int? {
        if let position = navigator.position(atUTF16: located), position != navigator.splitPosition {
            committed = position
            return nil
        }
        guard let cluster = navigator.cluster(aroundUTF16: located) else {
            return rollBack(from: from, direction: direction, step: step, context: context, timestamp: timestamp)
        }
        unit = .utf16
        let boundary = direction > 0 ? cluster.end : cluster.start
        committed = navigator.position(atUTF16: boundary) ?? from
        return launch(.move(from: located), offset: boundary - located, outcomes: [navigator.expectation(atUTF16: boundary)],
                      context: context, at: timestamp)
    }

    /// Back to where the probe started: the same count back returns there in either unit. The target
    /// stays, and the retry budget bounds another attempt.
    private mutating func rollBack(from: Int, direction: Int, step: Int, context: Context,
                                   timestamp: TimeInterval) -> Int {
        retriesLeft -= 1
        committed = from
        return launch(.move(from: nil), offset: -direction * step, outcomes: [navigator.expectation(at: from)],
                      context: context, at: timestamp)
    }

    /// A probe the host verifiably ignored: nothing is learned, the next probe from `from` takes the
    /// smallest step (one unit, which a grapheme host takes as one cluster), and the retry budget bounds
    /// the attempts.
    private mutating func probeIgnored(from: Int, direction: Int, context: Context) {
        retriesLeft -= 1
        adopt(context)
        // The caret is where the probe started, at its position in the context just adopted.
        ignoredProbe = (committed, direction)
    }

    /// Where a grapheme host's probe step leaves the caret: a position of the snapshot, or (with too
    /// few clusters left in it) that many characters past its edge, where only the snapshot's side can
    /// be checked.
    private func graphemeOutcome(from: Int, direction: Int, step: Int) -> CaretExpectation {
        let position = from + direction * step
        if navigator.boundaries.indices.contains(position) { return navigator.expectation(at: position) }
        let units = navigator.units
        return direction > 0
            ? CaretExpectation(before: Array(units.suffix(CaretExpectation.window)), after: nil,
                               hiddenBefore: position - navigator.lastPosition)
            : CaretExpectation(before: nil, after: Array(units.prefix(CaretExpectation.window)), hiddenAfter: -position)
    }

    /// The probe step for the cluster after `from`: its UTF-16 length when the snapshot has that many
    /// clusters to spare (both units then cross whole clusters), else the length of the scalar on
    /// the crossing side, which keeps a UTF-16 host off a surrogate pair's middle. After a probe from
    /// here was verifiably ignored, one unit: a grapheme host takes it as one cluster; a UTF-16 host,
    /// which never ignores a step inside the text, would stop mid-cluster and be completed.
    private func probeStep(from: Int, direction: Int) -> Int {
        if let ignoredProbe, ignoredProbe.from == from, ignoredProbe.direction == direction { return 1 }
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

    /// The next step toward the target: a repair, a move, a probe, or reaching past the snapshot.
    private mutating func advance(_ context: Context, timestamp: TimeInterval) -> Int? {
        if needsRepair { return repair(context, timestamp: timestamp) }
        if let offset = nextAdjustment(timestamp: timestamp, context: context) { return offset }
        return extendSnapshot(context, timestamp: timestamp)
    }

    /// Moves a caret the adopted context shows inside a cluster to the cluster's edge, in the direction
    /// of travel. The host counts UTF-16 units (no other can stop there).
    private mutating func repair(_ context: Context, timestamp: TimeInterval) -> Int? {
        needsRepair = false
        guard repairs < parameters.maximumRepairs else {
            isStalled = true
            return nil
        }
        repairs += 1
        let position = navigator.snapshotPosition
        if let split = navigator.snapshotSplit {
            let target = travelDirection > 0 ? position + 1 : position - 1
            committed = target
            return launch(.repair(target: target), offset: travelDirection > 0 ? split.forward : -split.back,
                          outcomes: [navigator.expectation(at: target)], context: context, at: timestamp)
        }
        // Between the halves of a surrogate pair, which the snapshot shows as two U+FFFD: one unit to
        // the pair's edge. Only the side away from the pair can be checked, from the unit the step
        // reaches (the snapshot's next boundary may be further: a U+FFFD for the trail half joins a
        // modifier or mark after it into one cluster).
        let target = min(max(position + travelDirection, 0), navigator.lastPosition)
        let units = navigator.units
        let split = min(max(navigator.boundaries[position] + travelDirection, 0), units.count)
        let outcome = travelDirection > 0
            ? CaretExpectation(before: nil, after: Array(units[split ..< min(units.count, split + CaretExpectation.window)]))
            : CaretExpectation(before: Array(units[max(0, split - CaretExpectation.window) ..< split]), after: nil)
        committed = target
        return launch(.repair(target: nil), offset: travelDirection, outcomes: [outcome], context: context, at: timestamp)
    }

    private mutating func nextAdjustment(timestamp: TimeInterval, context: Context) -> Int? {
        isStalled = false
        if let waypoint, committed == waypoint { self.waypoint = nil }
        let goal = waypoint ?? navigator.cursor
        guard flight == nil, committed != goal else { return nil }
        let direction = goal > committed ? 1 : -1
        if let unit {
            let offset = unit == .utf16 ? navigator.utf16Distance(from: committed, to: goal) : goal - committed
            travelDirection = direction
            let from = navigator.boundaries[committed]
            committed = goal
            return launch(.move(from: from), offset: offset, outcomes: [navigator.expectation(at: goal)],
                          context: context, at: timestamp)
        }
        // Until the unit is known, move only across single-code-unit characters, which both count alike.
        var reach = committed
        while reach != goal, abs(navigator.utf16Distance(from: reach, to: reach + direction)) == 1 {
            reach += direction
        }
        if reach != committed {
            let offset = reach - committed
            travelDirection = direction
            let from = navigator.boundaries[committed]
            committed = reach
            return launch(.move(from: from), offset: offset, outcomes: [navigator.expectation(at: reach)],
                          context: context, at: timestamp)
        }
        guard retriesLeft > 0 else {
            isStalled = true
            return nil
        }
        travelDirection = direction
        let step = probeStep(from: committed, direction: direction)
        // Outcomes: a UTF-16 host's, a grapheme host's, or the step ignored (the caret where it was).
        let outcomes = [navigator.expectation(atUTF16: navigator.boundaries[committed] + direction * step),
                        graphemeOutcome(from: committed, direction: direction, step: step),
                        navigator.expectation(at: committed)]
        return launch(.unitProbe(from: committed, direction: direction, step: step), offset: direction * step,
                      outcomes: outcomes, context: context, at: timestamp)
    }

    /// The host is caught up. Re-snapshots when the caret is near the snapshot's edge and the host
    /// shows more, and reaches for the line beyond the snapshot when the point is on it.
    private mutating func extendSnapshot(_ context: Context, timestamp: TimeInterval) -> Int? {
        guard flight == nil, waypoint == nil else { return nil }
        let knownBefore = navigator.boundaries[committed]
        let knownAfter = navigator.units.count - knownBefore
        let hostBefore = context.before.utf16.count
        let hostAfter = context.after.utf16.count
        if let edge = blocked, !isSoftEdge(edge) {
            let hostShowsMore = edge == .end ? hostAfter > knownAfter : hostBefore > knownBefore
            if hostShowsMore {
                adopt(context)
                return continueAfterAdopting(context, timestamp: timestamp)
            }
            // One jump just past the snapshot's edge, from where the caret is. A host ignores an offset
            // past the document's edge, so at the first or last line nothing visibly moves.
            let edgePosition = edge == .end ? navigator.lastPosition : 0
            guard let distance = hostOffset(from: committed, to: edgePosition) else {
                // The unit is still unknown across multi-unit text: walk to the edge first.
                waypoint = edgePosition
                return nextAdjustment(timestamp: timestamp, context: context)
            }
            blocked = nil
            travelDirection = edge == .end ? 1 : -1
            let units = navigator.units
            let crossed = edge == .end
                ? CaretExpectation(before: Array(units.suffix(CaretExpectation.window)), after: nil, hiddenBefore: 1)
                : CaretExpectation(before: nil, after: Array(units.prefix(CaretExpectation.window)), hiddenAfter: 1)
            let offset = distance + (edge == .end ? 1 : -1)
            // Outcomes: ignored (the caret where it was), or one character past the edge, which must show
            // something affirmative (an emptied field is neither).
            return launch(.edgeProbe(edge, offset: offset), offset: offset,
                          outcomes: [navigator.expectation(at: committed), crossed], context: context, at: timestamp)
        }
        // The caret reached a line whose start the snapshot does not show, coming from one it does.
        // When the host now shows more before it, re-snapshot and keep the point's real column.
        if xIsReal, navigator.line(of: committed, in: lines) < firstAnchoredLine, hostBefore > knownBefore {
            adopt(context, keepingColumn: true)
            return continueAfterAdopting(context, timestamp: timestamp)
        }
        let margin = parameters.resnapshotMargin
        let nearEnd = navigator.lastPosition - committed <= margin && hostAfter > knownAfter
        let nearStart = committed <= margin && hostBefore > knownBefore
        guard nearEnd || nearStart else { return nil }
        adopt(context)
        return continueAfterAdopting(context, timestamp: timestamp)
    }

    /// After adopting a context: repair the caret if it is inside a cluster, else head for the target.
    private mutating func continueAfterAdopting(_ context: Context, timestamp: TimeInterval) -> Int? {
        needsRepair ? repair(context, timestamp: timestamp) : nextAdjustment(timestamp: timestamp, context: context)
    }

    /// Takes the host's context as the snapshot, re-anchors the point and snaps the target again. A
    /// caret the context shows inside a cluster is marked for repair.
    private mutating func adopt(_ context: Context, linesCrossed: Int = 0, keepingColumn: Bool = false, advance: Int = 0) {
        resnapshot(context, linesCrossed: linesCrossed, keepingColumn: keepingColumn, advance: advance)
        waypoint = nil
        retarget()
        needsRepair = navigator.snapshotSplit != nil || Self.splitsSurrogatePair(context)
        if needsRepair {
            unit = .utf16
        } else {
            repairs = 0
        }
    }

    /// Takes the host's context as the new snapshot and re-anchors the point: the vertical offset from
    /// the caret's line is kept, less the lines the caret crossed to get here. The snapshot may start
    /// mid-paragraph, where its x coordinates are not real columns, so on the same line the point keeps
    /// its offset from the caret; after crossing a line, or when asked, x is kept as the column.
    /// `advance`: the caret went this many characters past `committed`, beyond what the old snapshot
    /// showed; the point keeps its offset from where `committed` is in the new one.
    private mutating func resnapshot(_ context: Context, linesCrossed: Int = 0, keepingColumn: Bool = false,
                                     advance: Int = 0) {
        let oldLine = navigator.line(of: committed, in: lines)
        let offset = point.y - center(oldLine)
        let columnOffset = point.x - navigator.x(of: committed, lines: lines, layout: layout)
        // Ambiguity is counted only while nothing changes.
        if context != snapshotContext {
            ambiguousProbes = [:]
            edgeTravel = [:]
            ignoredProbe = nil
        }
        snapshotContext = context
        navigator = TextNavigator(before: context.before, after: context.after)
        committed = navigator.cursor
        lines = layout.lines(in: navigator.text)
        firstAnchoredLine = Self.firstAnchoredLine(navigator.text, lines: lines, startsLine: context.startsLine)
        let line = navigator.line(of: committed, in: lines)
        let keepsColumn = linesCrossed != 0 || keepingColumn
        let anchor = min(max(committed - advance, 0), navigator.lastPosition)
        let x = keepsColumn ? point.x : navigator.x(of: anchor, lines: lines, layout: layout) + columnOffset
        if !keepsColumn { xIsReal = line >= firstAnchoredLine }
        point.place(x: x, y: center(line) + offset - Double(linesCrossed) * linePitch)
    }
}
