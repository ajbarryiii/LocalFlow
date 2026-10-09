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
/// The learned offset unit is kept for the current field only, and forgotten on hiding.
@MainActor
final class TrackpadDriver: AdjustmentOwner {
    private weak var controller: UIInputViewController?
    private var session: TrackpadSession?
    private var displayLink: CADisplayLink?
    private var documentID: UUID?
    private var generation = 0
    private var unitCache: (documentID: UUID, unit: CursorOffsetUnit)?
    private var touchRate = TouchRateEstimator()
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

    func begin(fieldWidth: CGFloat) {
        guard let controller else { return }
        let proxy = controller.textDocumentProxy
        guard let documentID = proxy.documentIdentifierIfAvailable else { return }
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: controller.traitCollection)
        let width = max(fieldWidth - CGFloat(parameters.fieldInsets), 40)
        self.documentID = documentID
        generation = currentGeneration()
        let unit = unitCache.flatMap { $0.documentID == documentID ? $0.unit : nil }
        if unit == nil { unitCache = nil }
        touchRate.beginGesture()
        var parameters = self.parameters
        parameters.eventStepScale = touchRate.eventStepScale
        session = TrackpadSession(
            before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
            unit: unit, parameters: parameters,
            layout: TextKitLineLayout(width: width, font: font),
            lineHeight: Double(font.lineHeight), layoutWidth: Double(width))
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
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

    /// The keyboard is hiding: roll back an outstanding probe now, then drop the session, its
    /// snapshot, the field's identity and its unit at once.
    func hide() {
        cancel(at: CACurrentMediaTime())
        unitCache = nil
        abort()
        documentID = nil
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

    private func finish(completed: Bool) {
        guard session != nil || displayLink != nil else { return }
        session = nil
        displayLink?.invalidate()
        displayLink = nil
        onFinished?(completed)
    }

    /// The proxy, if the field and the generation are still the ones the gesture started on.
    private var validProxy: UITextDocumentProxy? {
        guard let controller, let documentID else { return nil }
        let proxy = controller.textDocumentProxy
        guard proxy.documentIdentifierIfAvailable == documentID, currentGeneration() == generation else { return nil }
        return proxy
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard var session, let proxy = validProxy else { return abort() }
        let offset = session.frame(before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
                                   timestamp: link.timestamp)
        if let offset, offset != 0 { proxy.adjustTextPosition(byCharacterOffset: offset) }
        if let unit = session.unit, let documentID { unitCache = (documentID, unit) }
        self.session = session
        if session.isFinished(at: link.timestamp) { finish(completed: !session.isCancelled) }
    }
}
