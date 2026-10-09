import Foundation

/// What `adjustTextPosition(byCharacterOffset:)` counts in the host. Measured in the iOS 26.4
/// simulator: UIKit text fields and text views count UTF-16 code units and will stop inside a
/// grapheme cluster (between an emoji and its skin-tone modifier, or before a combining mark);
/// WebKit counts caret positions, which are grapheme clusters. Both ignore an offset that would
/// pass the document's start or end instead of clamping it.
enum CursorOffsetUnit: Equatable, Sendable {
    case utf16
    case grapheme
}

/// Lays text out into visual lines. The keyboard implements it with TextKit and the body font at
/// the estimated field width; tests use a fixed-width fake.
protocol LineLayout {
    /// The visual lines of `text` in order, as UTF-16 ranges that together cover the text. A line
    /// ending in a line break includes it. Text ending in a line break has an empty last line.
    func lines(in text: String) -> [Range<Int>]
    /// The caret's x position in points from the line's leading edge, at a UTF-16 offset in `line`.
    func x(atUTF16 offset: Int, line: Range<Int>, in text: String) -> Double
}

/// The text the proxy exposed around the caret, and a virtual cursor that moves inside it by whole
/// grapheme clusters. Positions are indexes into `boundaries`, the UTF-16 offsets of every
/// grapheme boundary, so no move splits a cluster. Held in memory only for one gesture.
struct TextNavigator {
    let text: String
    /// UTF-16 offsets of every caret position, ascending, from 0 to the text's UTF-16 length.
    let boundaries: [Int]
    /// The position of the host's caret when the snapshot was taken.
    let snapshotPosition: Int
    private(set) var cursor: Int
    let units: [UInt16]
    private let graphemes: [String]

    init(before: String, after: String) {
        let text = before + after
        self.text = text
        units = Array(text.utf16)
        let caret = before.utf16.count
        var offsets = [0]
        var pieces: [String] = []
        var offset = 0
        for character in text {
            let piece = String(character)
            let length = piece.utf16.count
            if caret > offset, caret < offset + length {
                // The host's caret sits inside this cluster after a UTF-16 step; keep it as a position.
                let codeUnits = Array(piece.utf16)
                pieces.append(String(decoding: codeUnits[..<(caret - offset)], as: UTF16.self))
                offsets.append(caret)
                pieces.append(String(decoding: codeUnits[(caret - offset)...], as: UTF16.self))
            } else {
                pieces.append(piece)
            }
            offset += length
            offsets.append(offset)
        }
        boundaries = offsets
        graphemes = pieces
        snapshotPosition = offsets.firstIndex(of: caret) ?? offsets.count - 1
        cursor = snapshotPosition
    }

    var lastPosition: Int { boundaries.count - 1 }

    var cursorUTF16Offset: Int { boundaries[cursor] }

    mutating func setCursor(_ position: Int) {
        cursor = min(max(position, 0), lastPosition)
    }

    /// The grapheme between `position` and `position + 1`, or nil outside the text.
    func grapheme(after position: Int) -> String? {
        graphemes.indices.contains(position) ? graphemes[position] : nil
    }

    func utf16Distance(from start: Int, to end: Int) -> Int {
        boundaries[end] - boundaries[start]
    }

    /// Whether the host's context, read with the caret at `position`, agrees with this snapshot
    /// around that position. Compares up to 32 code units on each side; a side the host shows
    /// nothing of, or the snapshot knows nothing of, cannot disagree.
    func agrees(before: String, after: String, at position: Int) -> Bool {
        agrees(before: before, after: after, atUTF16: boundaries[position])
    }

    /// `agrees` at any UTF-16 offset, including one inside a cluster, as after a UTF-16 step.
    func agrees(before: String, after: String, atUTF16 split: Int) -> Bool {
        guard (0...units.count).contains(split) else { return false }
        let window = 32
        let expectedBefore = units[max(0, split - window) ..< split]
        let expectedAfter = units[split ..< min(units.count, split + window)]
        let hostBefore = Array(before.utf16.suffix(window))
        let hostAfter = Array(after.utf16.prefix(window))
        let n = min(expectedBefore.count, hostBefore.count)
        let m = min(expectedAfter.count, hostAfter.count)
        guard expectedBefore.suffix(n).elementsEqual(hostBefore.suffix(n)),
              expectedAfter.prefix(m).elementsEqual(hostAfter.prefix(m)) else { return false }
        if n > 0 || m > 0 { return true }
        // Nothing to compare: agree only if both say the text is empty here.
        return expectedBefore.isEmpty == hostBefore.isEmpty && expectedAfter.isEmpty == hostAfter.isEmpty
    }

    /// Whether the host's context shares any text with this snapshot around `position`. When it
    /// does not (the snapshot knows nothing on one side and the host shows nothing on the other,
    /// as at the end of a UIKit paragraph), `agrees` cannot tell where the caret is.
    func canCompare(before: String, after: String, at position: Int) -> Bool {
        let split = boundaries[position]
        return (split > 0 && !before.isEmpty) || (split < units.count && !after.isEmpty)
    }

    // MARK: Lines

    /// The index of the line holding `position`. A position at a soft wrap belongs to the line it
    /// starts, as the caret is drawn there.
    func line(of position: Int, in lines: [Range<Int>]) -> Int {
        let offset = boundaries[position]
        if let index = lines.firstIndex(where: { $0.lowerBound <= offset && offset < $0.upperBound }) { return index }
        return max(lines.count - 1, 0)
    }

    func x(of position: Int, lines: [Range<Int>], layout: any LineLayout) -> Double {
        guard !lines.isEmpty else { return 0 }
        let line = lines[line(of: position, in: lines)]
        return layout.x(atUTF16: boundaries[position], line: line, in: text)
    }

    /// The caret position on `lineIndex` closest to `x`, never after the line's break. The end of a
    /// soft-wrapped line counts: the caret stays at that end instead of wrapping, as on Apple's keyboard.
    func position(nearestX x: Double, onLine lineIndex: Int, lines: [Range<Int>], layout: any LineLayout) -> Int {
        let line = lines[lineIndex]
        var best: (position: Int, distance: Double)?
        for (position, offset) in boundaries.enumerated() {
            guard offset >= line.lowerBound else { continue }
            guard offset <= line.upperBound else { break }
            // The position after a line break starts the next line.
            if offset > line.lowerBound, graphemes[position - 1].first?.isNewline == true { break }
            let distance = abs(layout.x(atUTF16: offset, line: line, in: text) - x)
            if best.map({ distance < $0.distance }) ?? true { best = (position, distance) }
        }
        if let best { return best.position }
        return boundaries.firstIndex { $0 >= line.lowerBound } ?? lastPosition
    }
}
