import UIKit

/// Runs a `TrackpadSession` against the text proxy: touch samples in, at most one
/// `adjustTextPosition` per display frame out. Before every adjustment it re-validates that the
/// field (a non-nil `documentIdentifier`) and the edit generation are the ones the gesture started
/// on; anything else aborts the session without another adjustment.
///
/// A session ends one of two ways (ARCHITECTURE.md, "Queued edits are bound to a field"):
/// completed (it settled after the lift, or timed out settling) or aborted (a stale field or
/// generation, an outside change, a system cancellation, hiding). `onFinished` says which, so
/// edits queued behind the gesture are flushed only after a completion.
///
/// The context snapshot lives only in the session and is dropped when it ends; on hiding, at once.
/// The learned offset unit, and whether the field reports each adjustment twice, are kept for the
/// current field only, and forgotten on hiding.
@MainActor
final class TrackpadDriver: AdjustmentOwner {
    private weak var controller: UIInputViewController?
    private var session: TrackpadSession?
    private var displayLink: CADisplayLink?
    private var documentID: UUID?
    private var generation = 0
    private var unitCache: (documentID: UUID, unit: CursorOffsetUnit)?
    /// Whether the field reports each adjustment twice (WebKit), once learned; kept like the unit.
    private var reportsCache: (documentID: UUID, reportsTwice: Bool)?
    private var touchRate = TouchRateEstimator()
    /// The keyboard hid while a cancelled session still watches a jump; see `hide`.
    private var isHiding = false
    var parameters = TrackpadParameters.standard
    /// The current edit generation, owned by `EditingCore`.
    var currentGeneration: () -> Int = { 0 }
    /// Called once the session is gone: `true` when it completed, `false` when it was aborted.
    var onFinished: ((Bool) -> Void)?

    init(controller: UIInputViewController) {
        self.controller = controller
    }

    /// A gesture is running or settling; text edits wait until it has finished.
    nonisolated var isActive: Bool { MainActor.assumeIsolated { session != nil } }

    /// The touch delivery rate measured so far and the step scale it gives, for Diagnostics.
    var measuredTouchRate: (rate: Double, scale: Double)? {
        touchRate.touchRate.map { ($0, touchRate.eventStepScale) }
    }

    /// Starts a gesture with the field's layout profile: its wrap width for this keyboard width, the
    /// body font at the current Dynamic Type size, and the layout's real line pitch.
    func begin(keyboardWidth: CGFloat, layout fieldLayout: FieldLayout) {
        guard let controller else { return }
        let proxy = controller.textDocumentProxy
        guard let documentID = proxy.documentIdentifierIfAvailable else { return }
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: controller.traitCollection)
        let profile = FieldLayoutParameters.standard
        let width = CGFloat(profile.wrapWidth(fieldLayout, keyboardWidth: Double(keyboardWidth)))
        let layout = TextKitLineLayout(width: width, font: font, lineFragmentPadding: CGFloat(profile.lineFragmentPadding))
        self.documentID = documentID
        generation = currentGeneration()
        let unit = unitCache.flatMap { $0.documentID == documentID ? $0.unit : nil }
        if unit == nil { unitCache = nil }
        let reportsTwice = reportsCache.flatMap { $0.documentID == documentID ? $0.reportsTwice : nil }
        if reportsTwice == nil { reportsCache = nil }
        touchRate.beginGesture()
        var parameters = self.parameters
        parameters.eventStepScale = touchRate.eventStepScale
        session = TrackpadSession(
            before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
            unit: unit, reportsTwice: reportsTwice, parameters: parameters,
            layout: layout, linePitch: layout.linePitch, layoutWidth: Double(width))
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    /// The offset unit learned in this field, if any; part of the field's fingerprint.
    func learnedUnit(for documentID: UUID?) -> CursorOffsetUnit? {
        guard let documentID, let unitCache, unitCache.documentID == documentID else { return nil }
        return unitCache.unit
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

    /// The system cancelled the gesture: an outstanding probe is rolled back at once, here, so nothing
    /// is left to a later frame; then the session only waits to hear from its last adjustment.
    func cancel(at timestamp: TimeInterval) {
        guard var session, let proxy = validProxy else { return abort() }
        let rollback = session.cancel(at: timestamp)
        self.session = session
        if let rollback, rollback != 0 { proxy.adjustTextPosition(byCharacterOffset: rollback) }
    }

    /// The keyboard is hiding: roll back an outstanding probe now and drop the snapshot, every expected
    /// context and the learned unit at once. Only a jump past the edge still out keeps the text-free
    /// session (and the field's identity) until its time limit, at most `syncTimeout`.
    func hide() {
        cancel(at: CACurrentMediaTime())
        unitCache = nil
        reportsCache = nil
        // The cancelled session already holds no text. A jump past the edge still out is watched until its
        // time limit, so a caret it leaves inside a hidden cluster is repaired; nothing else is kept.
        if let session, !session.isSettled {
            isHiding = true
            return
        }
        abort()
    }

    nonisolated func acknowledge(before: String?, after: String?) -> Bool {
        MainActor.assumeIsolated { session?.acknowledge(before: before, after: after) ?? false }
    }

    nonisolated func fits(before: String?, after: String?) -> Bool {
        MainActor.assumeIsolated { session?.fits(before: before, after: after) ?? false }
    }

    /// The document changed under the gesture, the field went away, or the keyboard hid: end at once,
    /// without another adjustment. Edits queued behind it are discarded.
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

    private func finish(completed: Bool) {
        if isHiding {
            isHiding = false
            documentID = nil
        }
        guard session != nil || displayLink != nil else { return }
        session = nil
        displayLink?.invalidate()
        displayLink = nil
        onFinished?(completed)
    }

    /// The proxy, if the field and the generation are still the ones the gesture started on. While a
    /// hidden keyboard finishes watching a cancelled jump, only the field counts: hiding itself advanced
    /// the generation.
    private var validProxy: UITextDocumentProxy? {
        guard let controller, let documentID else { return nil }
        let proxy = controller.textDocumentProxy
        guard proxy.documentIdentifierIfAvailable == documentID, isHiding || currentGeneration() == generation else {
            return nil
        }
        return proxy
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard var session, let proxy = validProxy else { return abort() }
        let offset = session.frame(before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
                                   timestamp: link.timestamp)
        if let offset, offset != 0 { proxy.adjustTextPosition(byCharacterOffset: offset) }
        if !isHiding, let documentID {
            if let unit = session.unit { unitCache = (documentID, unit) }
            if let reportsTwice = session.reportsTwice { reportsCache = (documentID, reportsTwice) }
        }
        self.session = session
        if session.isFinished(at: link.timestamp) { finish(completed: !session.isCancelled) }
    }
}
