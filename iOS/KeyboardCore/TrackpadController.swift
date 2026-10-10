import Foundation

/// Where the trackpad reads the field and moves the caret: the text proxy, or a fake in tests.
protocol TrackpadHost: AnyObject {
    /// The field's identity (`documentIdentifier`); nil while a field connects or goes away.
    var documentID: UUID? { get }
    var contextBefore: String? { get }
    var contextAfter: String? { get }
    /// `adjustTextPosition(byCharacterOffset:)`.
    func adjust(by offset: Int)
}

/// Runs a `TrackpadSession` against the host: touch samples in, at most one adjustment per display
/// frame out (`tick`). Before every adjustment it re-validates that the field (a non-nil identity) and
/// the edit generation are the ones the gesture started on; anything else ends the session without
/// another adjustment. The keyboard's `TrackpadDriver` supplies the display link and the TextKit
/// layout; everything else is here, so it is tested.
///
/// A session ends one of two ways: completed (it settled after the lift, timed out settling, or a key
/// was pressed and it resolved what it had out) or aborted (a stale field or generation, an outside
/// change, an ambiguous report, a system cancellation, hiding). `onFinished` says which. Typing never
/// waits on a session for long (ARCHITECTURE.md, "Typing correctness is paramount"): `settleNow`.
///
/// The context snapshot lives only in the session and is dropped when it ends; on cancelling or hiding,
/// at once. The learned offset unit, and whether the field reports each adjustment twice, are kept for
/// the current field only, and forgotten on hiding.
final class TrackpadController: AdjustmentOwner {
    private weak var host: TrackpadHost?
    private(set) var session: TrackpadSession?
    private var documentID: UUID?
    private var generation = 0
    private var unitCache: (documentID: UUID, unit: CursorOffsetUnit)?
    private var reportsCache: (documentID: UUID, reportsTwice: Bool)?
    private var touchRate = TouchRateEstimator()
    /// The keyboard hid while a cancelled session still watches a jump; see `hide`.
    private var isHiding = false
    /// Reports the last session in this field was still owed when it ended (a key settled it at once),
    /// by issue time: the next session expects them first.
    private var owedReports: (documentID: UUID, times: [TimeInterval])?
    var parameters = TrackpadParameters.standard
    /// The current edit generation, owned by `EditingCore`.
    var currentGeneration: () -> Int = { 0 }
    /// Called once the session is gone: `true` when it completed, `false` when it was aborted.
    var onFinished: ((Bool) -> Void)?
    /// The latest time a frame, a key or a cancellation was seen at.
    private(set) var lastTimestamp: TimeInterval = 0

    init(host: TrackpadHost) {
        self.host = host
    }

    /// A gesture is running or settling.
    var isActive: Bool { session != nil }

    /// A key is waiting for this session to resolve a probe it has out (`settleNow`).
    var isSettlingForTyping: Bool { session?.isSettlingNow == true }

    /// The touch delivery rate measured so far and the step scale it gives, for Diagnostics.
    var measuredTouchRate: (rate: Double, scale: Double)? {
        touchRate.touchRate.map { ($0, touchRate.eventStepScale) }
    }

    /// The offset unit learned in this field, if any; part of the field's fingerprint.
    func learnedUnit(for documentID: UUID?) -> CursorOffsetUnit? {
        guard let documentID, let unitCache, unitCache.documentID == documentID else { return nil }
        return unitCache.unit
    }

    /// Starts a gesture in the field the host serves now, laid out by `layout`. A session still running
    /// (a watch since hiding, or one a key waits on) ends first. False without a field identity.
    @discardableResult
    func begin(layout: any LineLayout, linePitch: Double, layoutWidth: Double) -> Bool {
        if session != nil { finish(completed: false) }
        guard let host, let documentID = host.documentID else { return false }
        self.documentID = documentID
        generation = currentGeneration()
        let unit = unitCache.flatMap { $0.documentID == documentID ? $0.unit : nil }
        if unit == nil { unitCache = nil }
        let reportsTwice = reportsCache.flatMap { $0.documentID == documentID ? $0.reportsTwice : nil }
        if reportsTwice == nil { reportsCache = nil }
        let owed = owedReports.flatMap { $0.documentID == documentID ? $0.times : nil } ?? []
        owedReports = nil
        touchRate.beginGesture()
        var parameters = self.parameters
        parameters.eventStepScale = touchRate.eventStepScale
        session = TrackpadSession(before: host.contextBefore, after: host.contextAfter, unit: unit,
                                  reportsTwice: reportsTwice,
                                  owedReports: owed.filter { lastTimestamp - $0 <= parameters.syncTimeout },
                                  parameters: parameters, layout: layout, linePitch: linePitch, layoutWidth: layoutWidth)
        return true
    }

    /// One delivered touch event's finger movement, at its touch timestamp.
    func move(dx: Double, dy: Double, timestamp: TimeInterval) {
        guard session != nil else { return }
        touchRate.record(timestamp)
        session?.setEventStepScale(touchRate.eventStepScale)
        session?.drag(dx: dx, dy: dy)
    }

    /// The finger lifted: the target stays, and settling continues toward it.
    func end(at timestamp: TimeInterval) {
        session?.end(at: timestamp)
    }

    /// A key was pressed: the session stops settling and the caret is accepted where it is
    /// (`TrackpadSession.settleNow`). True when the session is gone and the key may run at once; false
    /// while a probe it has out must be heard from first (at most `syncTimeout`), after which
    /// `onFinished` follows from `tick`.
    func settleNow(at timestamp: TimeInterval) -> Bool {
        lastTimestamp = max(lastTimestamp, timestamp)
        guard var session else { return true }
        guard isValid else {
            abort()
            return true
        }
        session.settleNow(at: timestamp)
        self.session = session
        guard session.isReadyForTyping else { return false }
        finish(completed: !session.isCancelled)
        return true
    }

    /// The system cancelled the gesture: an outstanding probe is rolled back at once, here, so nothing
    /// is left to a later frame; then the session only waits to hear from its last adjustment.
    func cancel(at timestamp: TimeInterval) {
        lastTimestamp = max(lastTimestamp, timestamp)
        guard var session else { return }
        guard isValid else { return abort() }
        let rollback = session.cancel(at: timestamp)
        self.session = session
        if let rollback, rollback != 0 { host?.adjust(by: rollback) }
    }

    /// The keyboard is hiding: roll back an outstanding probe now and drop the snapshot (and its
    /// laid-out copy), every expected context and the learned unit at once. Only a jump past the edge
    /// still out keeps the text-free session (and the field's identity) until its time limit, at most
    /// `syncTimeout`.
    func hide(at timestamp: TimeInterval) {
        cancel(at: timestamp)
        unitCache = nil
        reportsCache = nil
        owedReports = nil
        if let session, !session.isSettled {
            isHiding = true
            return
        }
        abort()
    }

    /// The document changed under the gesture, the field went away, or the keyboard hid: end at once,
    /// without another adjustment.
    func abort() {
        finish(completed: false)
    }

    /// The editing side saw another field, or none (as it does for every callback once hidden): end the
    /// gesture, unless a hidden keyboard is still watching a cancelled jump, which checks the field on
    /// every frame itself.
    func fieldChanged() {
        guard !isHiding else { return }
        abort()
    }

    /// One display frame.
    func tick(at timestamp: TimeInterval) {
        lastTimestamp = max(lastTimestamp, timestamp)
        guard var session else { return }
        guard isValid, let host else { return abort() }
        let offset = session.frame(before: host.contextBefore, after: host.contextAfter, timestamp: timestamp)
        self.session = session
        if let offset, offset != 0 { host.adjust(by: offset) }
        if !isHiding, let documentID {
            if let unit = session.unit { unitCache = (documentID, unit) }
            if let reportsTwice = session.reportsTwice { reportsCache = (documentID, reportsTwice) }
        }
        if session.isAmbiguous { return abort() }
        if session.isSettlingNow, session.isReadyForTyping { return finish(completed: !session.isCancelled) }
        if session.isFinished(at: timestamp) { finish(completed: !session.isCancelled) }
    }

    func acknowledge(before: String?, after: String?) -> Bool {
        session?.acknowledge(before: before, after: after) ?? false
    }

    func fits(before: String?, after: String?) -> Bool {
        session?.fits(before: before, after: after) ?? false
    }

    /// The field and the generation are still the ones the gesture started on. While a hidden keyboard
    /// finishes watching a cancelled jump, only the field counts: hiding itself advanced the generation.
    private var isValid: Bool {
        guard let host, let documentID, host.documentID == documentID else { return false }
        return isHiding || currentGeneration() == generation
    }

    private func finish(completed: Bool) {
        guard let session else {
            if isHiding { isHiding = false; documentID = nil }
            return
        }
        // Keys wait on this session: a caret its field shows inside a cluster goes to the cluster's edge
        // first, so they never split it (only a UTF-16 host stops there).
        if session.isSettlingNow, !completed, !session.isLandingOnABoundary, let host, let documentID,
           host.documentID == documentID,
           let split = TrackpadSession.visibleSplit(before: host.contextBefore, after: host.contextAfter) {
            host.adjust(by: session.repairDirection > 0 ? split.forward : -split.back)
        }
        if isHiding {
            isHiding = false
            documentID = nil
        }
        if let documentID, !session.owedReports.isEmpty {
            owedReports = (documentID, session.owedReports)
        }
        self.session = nil
        onFinished?(completed)
    }
}
