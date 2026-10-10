import Foundation

enum KeyboardLayer: Equatable, Sendable {
    case letters, numbers, symbols
}

enum KeyAction: Hashable, Sendable {
    /// Inserts the string; letters are stored lowercase and the shift state decides the case.
    case character(String)
    case shift
    case delete
    case space
    case returnKey
    case layer(KeyboardLayer)
    case nextKeyboard
}

struct KeyRect: Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    /// Zero inside the rectangle.
    func distanceSquared(toX px: Double, y py: Double) -> Double {
        let dx = max(x - px, 0, px - maxX)
        let dy = max(y - py, 0, py - maxY)
        return dx * dx + dy * dy
    }
}

struct PlacedKey: Equatable, Sendable {
    var action: KeyAction
    var frame: KeyRect
    /// The caption drawn on the key, or "" when the keyboard draws a symbol (shift, delete, globe,
    /// return).
    var label: String
}

/// Key sizes for a key area, after Apple's iPhone keyboard: in portrait 42-point keys with
/// 12-point row gaps in a 216-point area, letter keys sharing the width with 6 or 7-point gaps,
/// shift, delete and the layer keys about 1.3 letter widths, and return about 2.8.
struct KeyboardMetrics: Equatable, Sendable {
    var width: Double
    var height: Double
    var topPadding: Double
    var bottomPadding: Double
    var rowGap: Double
    var keyGap: Double
    var sideMargin: Double

    /// Portrait key-area height (Apple's keys without the predictive bar).
    static let regularHeight: Double = 216
    static let compactHeight: Double = 162

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
        let compact = height < 190
        topPadding = compact ? 5 : 8
        bottomPadding = compact ? 3 : 4
        rowGap = compact ? 7 : 12
        keyGap = compact || width >= 400 ? 7 : 6
        // Landscape keyboards keep the keys in a centered band instead of stretching them.
        sideMargin = compact ? max(3, (width - 700) / 2) : (width >= 400 ? 6 : 3)
    }

    var rowHeight: Double { max((height - topPadding - bottomPadding - 3 * rowGap) / 4, 1) }
    var letterWidth: Double { max((width - 2 * sideMargin - 9 * keyGap) / 10, 1) }
    var wideWidth: Double { (letterWidth * 1.32).rounded() }
    var returnWidth: Double { (letterWidth * 2.8).rounded() }

    func rowY(_ row: Int) -> Double { topPadding + Double(row) * (rowHeight + rowGap) }
}

enum KeyboardLayout {
    static let letterRows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    static let numberRows = ["1234567890", "-/:;()$&@\"", ".,?!'"]
    static let symbolRows = ["[]{}#%^*+=", "_\\|~<>€£¥•", ".,?!'"]

    static func keys(for layer: KeyboardLayer, metrics: KeyboardMetrics, showsGlobe: Bool) -> [PlacedKey] {
        let rows: [String]
        switch layer {
        case .letters: rows = letterRows
        case .numbers: rows = numberRows
        case .symbols: rows = symbolRows
        }
        let m = metrics
        var keys: [PlacedKey] = []
        func add(_ action: KeyAction, _ label: String, x: Double, row: Int, width: Double) {
            keys.append(PlacedKey(action: action, frame: KeyRect(x: x, y: m.rowY(row), width: width, height: m.rowHeight),
                                  label: label))
        }
        func addRow(_ characters: String, row: Int, startX: Double, width: Double) {
            for (index, character) in characters.enumerated() {
                add(.character(String(character)), String(character), x: startX + Double(index) * (width + m.keyGap),
                    row: row, width: width)
            }
        }
        func centeredStart(count: Int, width: Double) -> Double {
            (m.width - Double(count) * width - Double(count - 1) * m.keyGap) / 2
        }

        addRow(rows[0], row: 0, startX: m.sideMargin, width: m.letterWidth)
        addRow(rows[1], row: 1, startX: centeredStart(count: rows[1].count, width: m.letterWidth), width: m.letterWidth)

        let deleteX = m.width - m.sideMargin - m.wideWidth
        if layer == .letters {
            add(.shift, "", x: m.sideMargin, row: 2, width: m.wideWidth)
            addRow(rows[2], row: 2, startX: centeredStart(count: rows[2].count, width: m.letterWidth), width: m.letterWidth)
        } else {
            let toggle: (KeyAction, String) = layer == .numbers ? (.layer(.symbols), "#+=") : (.layer(.numbers), "123")
            add(toggle.0, toggle.1, x: m.sideMargin, row: 2, width: m.wideWidth)
            // Apple's five punctuation keys share the room between the two wide keys.
            let start = m.sideMargin + m.wideWidth + 2 * m.keyGap
            let end = deleteX - 2 * m.keyGap
            let count = Double(rows[2].count)
            let width = (end - start - (count - 1) * m.keyGap) / count
            addRow(rows[2], row: 2, startX: start, width: width)
        }
        add(.delete, "", x: deleteX, row: 2, width: m.wideWidth)

        var x = m.sideMargin
        let layerKey: (KeyAction, String) = layer == .letters ? (.layer(.numbers), "123") : (.layer(.letters), "ABC")
        add(layerKey.0, layerKey.1, x: x, row: 3, width: m.wideWidth)
        x += m.wideWidth + m.keyGap
        if showsGlobe {
            add(.nextKeyboard, "", x: x, row: 3, width: m.wideWidth)
            x += m.wideWidth + m.keyGap
        }
        let returnX = m.width - m.sideMargin - m.returnWidth
        add(.space, "space", x: x, row: 3, width: max(returnX - m.keyGap - x, 1))
        add(.returnKey, "", x: returnX, row: 3, width: m.returnWidth)
        return keys
    }

    /// The key under a touch, or the nearest one, so gaps between keys are never dead.
    static func nearestKey(toX x: Double, y: Double, in keys: [PlacedKey]) -> Int? {
        var best: (index: Int, distance: Double, center: Double)?
        for (index, key) in keys.enumerated() {
            let distance = key.frame.distanceSquared(toX: x, y: y)
            let dx = key.frame.midX - x, dy = key.frame.midY - y
            let center = dx * dx + dy * dy
            if let current = best, distance > current.distance || (distance == current.distance && center >= current.center) {
                continue
            }
            best = (index, distance, center)
        }
        return best?.index
    }
}
