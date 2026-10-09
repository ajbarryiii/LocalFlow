import UIKit

/// Runs a `TrackpadSession` against the text proxy: touch samples in, at most one
/// `adjustTextPosition` per display frame out. The context snapshot lives only in the session and
/// is dropped when the gesture settles. The learned offset unit is kept per document identifier in
/// this keyboard instance's memory, so the next gesture in the same field needs no probe.
@MainActor
final class TrackpadDriver {
    private weak var controller: UIInputViewController?
    private var session: TrackpadSession?
    private var displayLink: CADisplayLink?
    private var units: [UUID: CursorOffsetUnit] = [:]
    private var documentID: UUID?
    var parameters = TrackpadParameters.standard
    /// Called once the caret has settled after a gesture.
    var onSettled: (() -> Void)?

    init(controller: UIInputViewController) {
        self.controller = controller
    }

    var isActive: Bool { session != nil }

    func begin(fieldWidth: CGFloat) {
        guard let controller else { return }
        let proxy = controller.textDocumentProxy
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: controller.traitCollection)
        let advances = GlyphAdvances(font: font)
        documentID = proxy.documentIdentifierIfAvailable
        session = TrackpadSession(
            before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
            unit: documentID.flatMap { units[$0] }, parameters: parameters,
            layout: TextKitLineLayout(width: fieldWidth - CGFloat(parameters.fieldInsets), font: font),
            lineHeight: Double(font.lineHeight), advance: advances.advance(of:))
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func move(dx: Double, dy: Double, timestamp: TimeInterval) {
        session?.drag(dx: dx, dy: dy, timestamp: timestamp)
    }

    func end(at timestamp: TimeInterval) {
        session?.end(at: timestamp)
    }

    /// Drops everything at once, for example when the keyboard disappears.
    func cancel() {
        session = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let controller, var session else {
            cancel()
            return
        }
        let proxy = controller.textDocumentProxy
        let offset = session.frame(before: proxy.documentContextBeforeInput, after: proxy.documentContextAfterInput,
                                   timestamp: link.timestamp)
        if let offset, offset != 0 { proxy.adjustTextPosition(byCharacterOffset: offset) }
        if let unit = session.unit, let documentID { units[documentID] = unit }
        if session.isFinished(at: link.timestamp) {
            cancel()
            onSettled?()
        } else {
            self.session = session
        }
    }
}
