import UIKit

/// Runs a `TrackpadSession` against the text proxy: touch samples in, at most one
/// `adjustTextPosition` per display frame out. Before every adjustment it re-validates that the
/// field and the edit generation are the ones the gesture started on; anything else ends the session
/// without another adjustment. The context snapshot lives only in the session and is dropped when
/// it finishes. The learned offset unit is kept for the current field only.
@MainActor
final class TrackpadDriver {
    private weak var controller: UIInputViewController?
    private var session: TrackpadSession?
    private var displayLink: CADisplayLink?
    private var documentID: UUID?
    private var generation = 0
    private var unitCache: (documentID: UUID, unit: CursorOffsetUnit)?
    var parameters = TrackpadParameters.standard
    /// The current edit generation, owned by `KeyboardInput`.
    var currentGeneration: () -> Int = { 0 }
    /// Called before each adjustment, so callbacks it causes count as the gesture's own.
    var onAdjust: (() -> Void)?
    /// Called once the session is gone: settled, timed out, cancelled or stale.
    var onFinished: (() -> Void)?

    init(controller: UIInputViewController) {
        self.controller = controller
    }

    /// A gesture is running or settling; text edits wait until it has finished.
    var isActive: Bool { session != nil }

    func begin(fieldWidth: CGFloat) {
        guard let controller else { return }
        let proxy = controller.textDocumentProxy
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: controller.traitCollection)
        let width = max(fieldWidth - CGFloat(parameters.fieldInsets), 40)
        documentID = proxy.documentIdentifierIfAvailable
        generation = currentGeneration()
        let unit = unitCache.flatMap { $0.documentID == documentID ? $0.unit : nil }
        if unit == nil { unitCache = nil }
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

    /// One delivered touch event's finger movement.
    func move(dx: Double, dy: Double) {
        session?.drag(dx: dx, dy: dy)
    }

    /// The finger lifted: pending adjustments still land.
    func end(at timestamp: TimeInterval) {
        session?.end(at: timestamp)
    }

    /// The system cancelled the gesture, or the keyboard is hiding: an outstanding probe is rolled
    /// back, then the session ends.
    func cancel(at timestamp: TimeInterval) {
        session?.cancel(at: timestamp)
    }

    /// Whether a host callback fits the gesture's own adjustments.
    func explains(before: String?, after: String?) -> Bool {
        session?.explains(before: before, after: after) ?? false
    }

    /// A host callback that fits the gesture: the host's own context is now readable.
    func hostDidChange() {
        session?.hostDidChange()
    }

    /// The document changed under the gesture or the field went away: stop without another adjustment.
    func terminate() {
        guard session != nil || displayLink != nil else { return }
        session = nil
        displayLink?.invalidate()
        displayLink = nil
        onFinished?()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let controller, var session else {
            terminate()
            return
        }
        let proxy = controller.textDocumentProxy
        guard proxy.documentIdentifierIfAvailable == documentID, currentGeneration() == generation else {
            terminate()
            return
        }
        let offset = session.frame(before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
                                   timestamp: link.timestamp)
        if let offset, offset != 0 {
            onAdjust?()
            proxy.adjustTextPosition(byCharacterOffset: offset)
        }
        if let unit = session.unit, let documentID { unitCache = (documentID, unit) }
        if session.isFinished(at: link.timestamp) {
            self.session = session
            terminate()
        } else {
            self.session = session
        }
    }
}
