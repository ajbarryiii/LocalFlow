import AppKit

/// The app waveform without its tile. Transparent pupils allow macOS to tint
/// the entire glyph correctly on light, dark, and highlighted menu bars.
enum LocalFlowMenuBarIcon {
    private static let standard = makeImage(includeBadge: false)
    private static let development = makeImage(includeBadge: true)

    static func image(isDevelopmentBuild: Bool) -> NSImage {
        isDevelopmentBuild ? development : standard
    }

    private static func makeImage(includeBadge: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { rect in
            let scale = rect.width / 716
            let path = NSBezierPath()
            path.windingRule = .evenOdd
            let heights: [CGFloat] = [128, 300, 428, 352, 232, 352, 428, 300, 128]
            for (index, height) in heights.enumerated() {
                path.append(NSBezierPath(
                    roundedRect: NSRect(x: rect.minX + CGFloat(index) * 82 * scale,
                                        y: rect.midY - height * scale / 2,
                                        width: 60 * scale, height: height * scale),
                    xRadius: 30 * scale, yRadius: 30 * scale
                ))
            }
            let pupilRadius = 24 * scale
            for position: CGFloat in [194, 522] {
                path.appendOval(in: NSRect(x: rect.minX + position * scale - pupilRadius,
                                          y: rect.midY - pupilRadius,
                                          width: pupilRadius * 2, height: pupilRadius * 2))
            }
            if includeBadge {
                let unit = rect.width / 20
                path.appendOval(in: NSRect(x: rect.minX + 17.35 * unit,
                                          y: rect.minY + 14.05 * unit,
                                          width: 1.3 * unit, height: 1.3 * unit))
            }
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = AppName.displayName
        return image
    }
}
