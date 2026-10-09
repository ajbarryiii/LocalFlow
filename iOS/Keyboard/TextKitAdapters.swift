import UIKit

/// `LineLayout` with TextKit: the snapshot laid out in the body font at the estimated width of the
/// host's field. The host's real font and width are unknown to a keyboard, so soft wraps are an
/// estimate; hard line breaks are exact. Holds the snapshot only while a gesture runs.
final class TextKitLineLayout: LineLayout {
    private let font: UIFont
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container: NSTextContainer
    private var laidOutText: String?

    init(width: CGFloat, font: UIFont) {
        self.font = font
        container = NSTextContainer(size: CGSize(width: max(width, 40), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    func lines(in text: String) -> [Range<Int>] {
        layOut(text)
        var lines: [Range<Int>] = []
        let glyphs = NSRange(location: 0, length: manager.numberOfGlyphs)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { [manager] _, _, _, glyphRange, _ in
            let characters = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            lines.append(characters.location ..< characters.location + characters.length)
        }
        let length = (text as NSString).length
        if lines.isEmpty { return [0 ..< length] }
        // The caret after a final line break sits on a line TextKit draws as the extra fragment.
        if text.last?.isNewline == true { lines.append(length ..< length) }
        return lines
    }

    func x(atUTF16 offset: Int, line: Range<Int>, in text: String) -> Double {
        layOut(text)
        let length = (text as NSString).length
        guard offset > line.lowerBound, line.lowerBound < length else { return 0 }
        if offset >= length || offset >= line.upperBound {
            // The end of the line: after its last glyph.
            let glyph = manager.glyphIndexForCharacter(at: max(min(offset, length) - 1, 0))
            let used = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return Double(used.maxX - fragment.minX)
        }
        let glyph = manager.glyphIndexForCharacter(at: offset)
        return Double(manager.location(forGlyphAt: glyph).x)
    }

    private func layOut(_ text: String) {
        guard text != laidOutText else { return }
        laidOutText = text
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        manager.ensureLayout(for: container)
    }
}
