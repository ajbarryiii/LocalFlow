import UIKit

/// `LineLayout` with TextKit 1: the snapshot laid out in the body font at the width of the field
/// profile in use (`FieldLayoutParameters`), with no line-fragment padding. The host's real font and
/// width are unknown to a keyboard, so soft wraps are an estimate; hard line breaks are exact. Holds
/// the snapshot only while a gesture runs.
final class TextKitLineLayout: LineLayout {
    private let font: UIFont
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container: NSTextContainer
    private var laidOutText: String?

    init(width: CGFloat, font: UIFont, lineFragmentPadding: CGFloat = 0) {
        self.font = font
        container = NSTextContainer(size: CGSize(width: max(width, 40), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = lineFragmentPadding
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    /// The line advance this layout uses: measured between two laid-out lines (TextKit adds the
    /// font's leading to its line height), else line height plus leading. Text views advance by this,
    /// not by `font.lineHeight`.
    lazy var linePitch: Double = {
        let probe = NSTextStorage(string: "X\nX", attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 1_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        probe.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        var tops: [CGFloat] = []
        let glyphs = NSRange(location: 0, length: manager.numberOfGlyphs)
        manager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in tops.append(rect.minY) }
        if tops.count >= 2, tops[1] > tops[0] { return Double(tops[1] - tops[0]) }
        return FieldLayoutParameters.linePitch(lineHeight: Double(font.lineHeight), leading: Double(font.leading))
    }()

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

extension FieldTraits {
    /// The traits the field reports through the proxy. Content-free by construction: enum raw values,
    /// flags, and a content type identifier (any non-identifier reads as "custom").
    @MainActor
    init(proxy: UITextDocumentProxy) {
        self.init()
        keyboardType = proxy.keyboardType?.rawValue ?? -1
        returnKeyType = proxy.returnKeyType?.rawValue ?? -1
        autocapitalization = proxy.autocapitalizationType?.rawValue ?? -1
        autocorrection = proxy.autocorrectionType?.rawValue ?? -1
        spellChecking = proxy.spellCheckingType?.rawValue ?? -1
        smartQuotes = proxy.smartQuotesType?.rawValue ?? -1
        smartDashes = proxy.smartDashesType?.rawValue ?? -1
        smartInsertDelete = proxy.smartInsertDeleteType?.rawValue ?? -1
        keyboardAppearance = proxy.keyboardAppearance?.rawValue ?? -1
        inlinePrediction = proxy.inlinePredictionType?.rawValue ?? -1
        mathExpressionCompletion = proxy.mathExpressionCompletionType?.rawValue ?? -1
        writingToolsBehavior = proxy.writingToolsBehavior?.rawValue ?? -1
        enablesReturnKeyAutomatically = proxy.enablesReturnKeyAutomatically ?? false
        isSecureTextEntry = proxy.isSecureTextEntry ?? false
        textContentType = proxy.textContentType.map { type in
            let raw = type.rawValue
            return raw.count <= 40 && raw.allSatisfy({ $0.isASCII && $0.isLetter }) ? raw : "custom"
        }
    }
}
