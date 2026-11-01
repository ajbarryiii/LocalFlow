import UIKit

/// Key colors after iOS 26's keyboard: every key shares one fill, and action return keys and caps lock take the
/// accent (`BrandPalette.accent`, ARCHITECTURE.md, "Keyboard look"): the label colour's side, monochrome. Dynamic, so they follow light and dark
/// mode, and Increase Contrast, without re-rendering.
enum KeyPalette {
    static let fill = BrandPalette.dynamic(\.keyFill)
    static let pressedFill = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.58, alpha: 1) : UIColor(white: 0.80, alpha: 1)
    }
    /// With Increase Contrast every key gets a visible edge.
    static let edge = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.85, alpha: 0.7) : UIColor(white: 0.25, alpha: 0.6)
    }
    /// A light key with dark ink on the dark keyboard, a near-black one with white ink on the light keyboard.
    static let prominentFill = BrandPalette.dynamic(\.accent.color)
    static let prominentInk = BrandPalette.dynamic(\.accent.ink)
    /// A disabled return key (`ReturnKeyRule`): the plain fill, its caption dimmed.
    static let disabledAlpha: CGFloat = 0.35
    static let shadow = UIColor(white: 0, alpha: 1).cgColor
    static let cornerRadius = CGFloat(KeyboardMetrics.keyCornerRadius)
}

/// One key's cap: drawing only. The key area tracks touches and owns the state.
final class KeyCapView: UIView {
    private let label = UILabel()
    private let icon = UIImageView()
    private var isProminent = false
    private var isEnabled = true

    var isPressed = false {
        didSet { if isPressed != oldValue { updateFill() } }
    }

    /// Trackpad mode blanks the caps, as on Apple's keyboard.
    var isBlank = false {
        didSet { updateCaptionAlpha() }
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
        registerForTraitChanges([UITraitAccessibilityContrast.self, UITraitUserInterfaceStyle.self]) { (view: KeyCapView, _: UITraitCollection) in
            view.updateEdge()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `enabled`: a disabled key keeps the plain fill and dims its caption (a disabled action key is not tinted).
    func configure(title: String?, symbol: String?, font: UIFont, weight: UIImage.SymbolWeight = .regular,
                   prominent: Bool = false, secondary: Bool = false, enabled: Bool = true) {
        let tinted = prominent && enabled
        label.text = title
        label.font = font
        label.textColor = tinted ? KeyPalette.prominentInk : (secondary ? .secondaryLabel : .label)
        icon.image = symbol.flatMap {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: tinted ? .semibold : weight))
        }
        icon.tintColor = tinted ? KeyPalette.prominentInk : .label
        isProminent = tinted
        isEnabled = enabled
        updateCaptionAlpha()
        updateFill()
        updateEdge()
    }

    /// The caption's opacity, from both states: hidden while blank, dimmed while disabled.
    private func updateCaptionAlpha() {
        let alpha = isBlank ? 0 : (isEnabled ? 1 : KeyPalette.disabledAlpha)
        label.alpha = alpha
        icon.alpha = alpha
    }

    /// Increase Contrast: a visible edge on every key; an accent key's own edge where it has one (a CGColor, so
    /// resolved here).
    private func updateEdge() {
        let high = traitCollection.accessibilityContrast == .high
        let palette = BrandPalette(traitCollection)
        let accentEdge = isProminent ? palette.accent.edge : nil
        if let accentEdge {
            layer.borderWidth = CGFloat(palette.edgeWidth)
            layer.borderColor = UIColor(accentEdge).cgColor
        } else {
            layer.borderWidth = high ? 1 : 0
            layer.borderColor = high ? KeyPalette.edge.resolvedColor(with: traitCollection).cgColor : nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 3, dy: 0)
        icon.frame = bounds
        // An explicit path keeps the shadow off the offscreen-rendering path.
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: KeyPalette.cornerRadius).cgPath
    }

    private func updateFill() {
        backgroundColor = isProminent ? (isPressed ? KeyPalette.prominentFill.withAlphaComponent(0.65) : KeyPalette.prominentFill)
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
        // A top-row bubble must stay below the keyboard's top, where iOS clips an extension's drawing: with the
        // 48 pt bar, 8 pt padding and a 42 pt key, a 4 pt gap leaves about 3.7 pt (ARCHITECTURE.md, "Reach above
        // the keys"). Landscape leaves about 6 pt with its 6 pt gap.
        let gap: CGFloat = compact ? 6 : 4
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

/// The press-and-hold alternates row (`KeyTouchModel.alternatesTouch`): one bubble over the held key's cells, the
/// picked cell highlighted in the accent. It takes no touches; the held finger drives it.
final class KeyAlternatesView: UIView {
    private let bubble = CAShapeLayer()
    private let highlight = CALayer()
    private var labels: [UILabel] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        bubble.shadowColor = KeyPalette.shadow
        bubble.shadowOpacity = 0.3
        bubble.shadowRadius = 4
        bubble.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(bubble)
        highlight.cornerRadius = 7
        highlight.cornerCurve = .continuous
        layer.addSublayer(highlight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `cells` are in the superview's coordinates, one per option, `selected` the picked one.
    func show(_ options: [String], cells: [CGRect], selected: Int, compact: Bool) {
        guard let first = cells.first else { return hide() }
        let union = cells.reduce(first) { $0.union($1) }
        let outer = union.insetBy(dx: -3, dy: -3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = outer
        bubble.frame = bounds
        let path = UIBezierPath(roundedRect: bounds, cornerRadius: 10).cgPath
        bubble.path = path
        bubble.shadowPath = path
        bubble.fillColor = KeyPalette.fill.resolvedColor(with: traitCollection).cgColor
        bubble.strokeColor = traitCollection.accessibilityContrast == .high
            ? KeyPalette.edge.resolvedColor(with: traitCollection).cgColor : nil
        while labels.count < options.count {
            let label = UILabel()
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            addSubview(label)
            labels.append(label)
        }
        let weight: UIFont.Weight = traitCollection.legibilityWeight == .bold ? .semibold : .regular
        let size: CGFloat = compact ? 22 : 26
        for (index, label) in labels.enumerated() {
            guard index < options.count else {
                label.isHidden = true
                continue
            }
            label.isHidden = false
            label.text = options[index]
            label.font = .systemFont(ofSize: options[index].count > 1 ? size * 0.65 : size, weight: weight)
            label.frame = cells[index].offsetBy(dx: -outer.minX, dy: -outer.minY)
            label.textColor = index == selected ? KeyPalette.prominentInk : .label
        }
        let picked = cells[min(max(selected, 0), cells.count - 1)].offsetBy(dx: -outer.minX, dy: -outer.minY)
        highlight.frame = picked.insetBy(dx: 1, dy: 3)
        highlight.backgroundColor = KeyPalette.prominentFill.resolvedColor(with: traitCollection).cgColor
        // The accent's edge where it has one, as on the action keys.
        let palette = BrandPalette(traitCollection), edge = palette.accent.edge
        highlight.borderWidth = edge == nil ? 0 : CGFloat(palette.edgeWidth)
        highlight.borderColor = edge.map { UIColor($0).cgColor }
        CATransaction.commit()
        isHidden = false
    }

    func hide() {
        isHidden = true
    }
}
