import UIKit

/// The trackpad's UIKit side: the display link that runs `TrackpadController` once per frame, and the
/// TextKit layout of the field's profile. The session, its validation and its lifetime are in
/// `TrackpadController` (KeyboardCore), where they are tested.
@MainActor
final class TrackpadDriver {
    private weak var controller: UIInputViewController?
    let trackpad: TrackpadController
    private var displayLink: CADisplayLink?

    init(controller: UIInputViewController, trackpad: TrackpadController) {
        self.controller = controller
        self.trackpad = trackpad
    }

    /// A gesture's layout for the field's profile: its wrap width for this keyboard width, the body
    /// font at the current Dynamic Type size, and the layout's real line pitch.
    func layout(keyboardWidth: CGFloat, profile fieldLayout: FieldLayout)
        -> (layout: TextKitLineLayout, linePitch: Double, width: Double)? {
        guard let controller else { return nil }
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: controller.traitCollection)
        let profile = FieldLayoutParameters.standard
        let width = CGFloat(profile.wrapWidth(fieldLayout, keyboardWidth: Double(keyboardWidth)))
        let layout = TextKitLineLayout(width: width, font: font, lineFragmentPadding: CGFloat(profile.lineFragmentPadding))
        return (layout, layout.linePitch, Double(width))
    }

    /// Runs frames while a session is active; stops by itself once none is.
    func run() {
        guard trackpad.isActive, displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        trackpad.tick(at: link.timestamp)
        guard !trackpad.isActive else { return }
        displayLink?.invalidate()
        displayLink = nil
    }
}
