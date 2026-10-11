import UIKit

/// Key colors after iOS 26's keyboard: every key shares one fill, and action return keys are
/// tinted. Dynamic, so they follow light and dark mode without re-rendering.
enum KeyPalette {
    static let fill = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white }
    static let pressedFill = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.58, alpha: 1) : UIColor(white: 0.80, alpha: 1)
    }
    static let prominentFill = UIColor.systemBlue
    static let shadow = UIColor(white: 0, alpha: 1).cgColor
    static let cornerRadius: CGFloat = 8.5
}

/// One key's cap: drawing only. The key area tracks touches and owns the state.
final class KeyCapView: UIView {
    private let label = UILabel()
    private let icon = UIImageView()
    private var isProminent = false

    var isPressed = false {
        didSet { if isPressed != oldValue { updateFill() } }
    }

    /// Trackpad mode blanks the caps, as on Apple's keyboard.
    var isBlank = false {
        didSet {
            label.alpha = isBlank ? 0 : 1
            icon.alpha = isBlank ? 0 : 1
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        layer.cornerRadius = KeyPalette.cornerRadius
        layer.cornerCurve = .continuous
        layer.shadowColor = KeyPalette.shadow
        layer.shadowOpacity = 0.28
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.baselineAdjustment = .alignCenters
        icon.contentMode = .center
        addSubview(label)
        addSubview(icon)
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String?, symbol: String?, font: UIFont, prominent: Bool, secondary: Bool) {
        label.text = title
        label.font = font
        label.textColor = prominent ? .white : (secondary ? .secondaryLabel : .label)
        icon.image = symbol.flatMap {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular))
        }
        icon.tintColor = prominent ? .white : .label
        isProminent = prominent
        updateFill()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 3, dy: 0)
        icon.frame = bounds
        // An explicit path keeps the shadow off the offscreen-rendering path.
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: KeyPalette.cornerRadius).cgPath
    }

    private func updateFill() {
        backgroundColor = isProminent ? (isPressed ? KeyPalette.prominentFill.withAlphaComponent(0.7) : KeyPalette.prominentFill)
            : (isPressed ? KeyPalette.pressedFill : KeyPalette.fill)
    }
}

/// The enlarged character above a pressed key: a bubble joined to the key by a neck, like Apple's.
final class KeyCalloutView: UIView {
    private let shape = CAShapeLayer()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        shape.shadowColor = KeyPalette.shadow
        shape.shadowOpacity = 0.25
        shape.shadowRadius = 3
        shape.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(shape)
        label.textAlignment = .center
        label.textColor = .label
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `text` for the key at `key` (in the superview's coordinates), kept inside `container`.
    func show(_ text: String, over key: CGRect, within container: CGRect, compact: Bool) {
        let extra = min(12, key.width * 0.35)
        let bubbleHeight = key.height * (compact ? 1.0 : 1.15)
        let gap: CGFloat = compact ? 6 : 10
        var bubble = CGRect(x: key.midX - key.width / 2 - extra, y: key.minY - gap - bubbleHeight,
                            width: key.width + 2 * extra, height: bubbleHeight)
        bubble.origin.x = min(max(bubble.minX, container.minX + 1), container.maxX - bubble.width - 1)
        let union = bubble.union(key)
        frame = union

        let k = key.offsetBy(dx: -union.minX, dy: -union.minY)
        let b = bubble.offsetBy(dx: -union.minX, dy: -union.minY)
        let r = KeyPalette.cornerRadius, br: CGFloat = 10
        let path = UIBezierPath()
        path.move(to: CGPoint(x: k.minX + r, y: k.maxY))
        path.addArc(withCenter: CGPoint(x: k.minX + r, y: k.maxY - r), radius: r, startAngle: .pi / 2, endAngle: .pi,
                    clockwise: true)
        path.addLine(to: CGPoint(x: k.minX, y: k.minY + 4))
        path.addCurve(to: CGPoint(x: b.minX, y: b.maxY), controlPoint1: CGPoint(x: k.minX, y: k.minY - gap / 2),
                      controlPoint2: CGPoint(x: b.minX, y: b.maxY + gap / 2))
        path.addLine(to: CGPoint(x: b.minX, y: b.minY + br))
        path.addArc(withCenter: CGPoint(x: b.minX + br, y: b.minY + br), radius: br, startAngle: .pi, endAngle: 1.5 * .pi,
                    clockwise: true)
        path.addLine(to: CGPoint(x: b.maxX - br, y: b.minY))
        path.addArc(withCenter: CGPoint(x: b.maxX - br, y: b.minY + br), radius: br, startAngle: 1.5 * .pi, endAngle: 0,
                    clockwise: true)
        path.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
        path.addCurve(to: CGPoint(x: k.maxX, y: k.minY + 4), controlPoint1: CGPoint(x: b.maxX, y: b.maxY + gap / 2),
                      controlPoint2: CGPoint(x: k.maxX, y: k.minY - gap / 2))
        path.addLine(to: CGPoint(x: k.maxX, y: k.maxY - r))
        path.addArc(withCenter: CGPoint(x: k.maxX - r, y: k.maxY - r), radius: r, startAngle: 0, endAngle: .pi / 2,
                    clockwise: true)
        path.close()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = path.cgPath
        shape.shadowPath = path.cgPath
        shape.fillColor = KeyPalette.fill.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
        label.font = .systemFont(ofSize: compact ? 28 : 36, weight: .regular)
        label.text = text
        label.frame = b
        isHidden = false
    }

    func hide() {
        isHidden = true
    }
}
