import Foundation

enum KeyboardLayer: Equatable, Sendable {
    /// `emoji` is the emoji panel: its grid and jump bar are drawn by the keyboard, and its only keys are the
    /// bottom row's (`KeyboardLayout.keys`).
    case letters, numbers, symbols, emoji
}

/// The kind of field, from its keyboard type. Only the bottom row differs (ARCHITECTURE.md, "Layout and keys"):
/// email fields get "@" and "." beside a narrower space bar, URL fields ".", "/" and ".com" in place of the space
/// bar, as on Apple's keyboard, and web search fields a "." beside the space bar. Everything else is `standard`.
enum KeyboardField: Equatable, Sendable {
    case standard, email, url, webSearch

    /// The bottom row has the emoji key everywhere but in email and URL fields, where an emoji is never wanted and
    /// the field's own keys need the room.
    var showsEmojiKey: Bool { self == .standard || self == .webSearch }
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

extension KeyAction {
    /// The letter a–z this key types, as 0–25; nil for every other key.
    var letterIndex: Int? {
        guard case .character(let character) = self, let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1, ("a" ... "z").contains(scalar) else { return nil }
        return Int(scalar.value - Unicode.Scalar("a").value)
    }
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

    /// The keys' corner radius, in points.
    static let keyCornerRadius: Double = 8.5

    /// Portrait key-area height (Apple's keys without the predictive bar).
    static let regularHeight: Double = 216
    static let compactHeight: Double = 162

    /// The dictation bar above the keys, and its controls, centred in it (ARCHITECTURE.md, "Top row").
    static let barHeight: Double = 56
    static let compactBarHeight: Double = 40
    static let barControlHeight: Double = 38
    static let compactBarControlHeight: Double = 32

    /// How far above its top the key area takes touches: the strip of the bar below its controls
    /// (ARCHITECTURE.md, "Dropped taps: reach, skids and counters").
    static func reachAboveKeys(compact: Bool) -> Double {
        compact ? (compactBarHeight - compactBarControlHeight) / 2 : (barHeight - barControlHeight) / 2
    }

    /// Whether a touch at (x, y) in the bar's own coordinates goes to the keys: anywhere in the bar outside every
    /// control's frame (an edge is the control's; each control's tap area is exactly its frame); with no control
    /// frames known, only the strip below the controls (`reachAboveKeys`). ARCHITECTURE.md, "Reach above the keys".
    static func barPointGoesToKeys(x: Double, y: Double, barHeight: Double, compact: Bool, controls: [KeyRect]) -> Bool {
        guard y >= 0, y <= barHeight else { return false }
        guard !controls.isEmpty else { return y >= barHeight - reachAboveKeys(compact: compact) }
        return controls.allSatisfy { $0.distanceSquared(toX: x, y: y) > 0 }
    }

    /// The Start/Stop capsule's tap area is its frame inset this much at the sides and bottom, where the keys take
    /// the rest (user decision, 2026-10-18: the capsule is never missed, and fast top-row taps land around it).
    static let startHitInset: Double = 6

    /// How far below the key area's top Stop's tap area reaches while dictation is starting or recording: through
    /// the top row and half the gap below it.
    static func stopReachIntoKeys(compact: Bool) -> Double {
        let metrics = KeyboardMetrics(width: 1, height: compact ? compactHeight : regularHeight)
        return metrics.rowY(0) + metrics.rowHeight + metrics.rowGap / 2
    }

    /// The Start/Stop capsule's tap area, in the bar's coordinates, from its frame there: inset by `startHitInset` at
    /// the sides and bottom and reaching up to the bar's top; while `capturing` (starting or recording), down
    /// through the top row of keys instead (`stopReachIntoKeys`). ARCHITECTURE.md, "Reach and touch regions".
    static func startTapArea(capsule: KeyRect, barHeight: Double, compact: Bool, capturing: Bool) -> KeyRect {
        let bottom = capturing ? barHeight + stopReachIntoKeys(compact: compact) : capsule.maxY - startHitInset
        return KeyRect(x: capsule.x + startHitInset, y: 0, width: max(capsule.width - 2 * startHitInset, 0), height: max(bottom, 0))
    }

    /// Whether a touch at (x, y) in the key area's coordinates is the Start capsule's: inside `start`, its tap area
    /// in the bar's coordinates, which reaches into the keys only while capturing (an edge is the capsule's).
    static func keyPointGoesToStart(x: Double, y: Double, barHeight: Double, start: KeyRect?) -> Bool {
        guard y >= 0, let start else { return false }
        return start.distanceSquared(toX: x, y: y + barHeight) == 0
    }

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

    /// The URL field's key that types a whole domain ending; holding it offers others (`KeyAlternates`).
    static let dotCom = ".com"

    /// Every key of `layer` for a field of kind `field`. The letter, number and symbol rows are the same in every
    /// field; only the bottom row differs (`KeyboardField`). The emoji layer has the bottom row's layer key, the
    /// globe and delete; its grid and jump bar fill the rest (`emojiGridFrame`, `emojiJumpBarFrame`).
    static func keys(for layer: KeyboardLayer, metrics: KeyboardMetrics, showsGlobe: Bool,
                     field: KeyboardField = .standard) -> [PlacedKey] {
        let rows: [String]
        switch layer {
        case .letters: rows = letterRows
        case .numbers: rows = numberRows
        case .symbols: rows = symbolRows
        case .emoji: return emojiKeys(metrics: metrics, showsGlobe: showsGlobe)
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
        if field.showsEmojiKey {
            add(.layer(.emoji), "", x: x, row: 3, width: m.wideWidth)
            x += m.wideWidth + m.keyGap
        }
        let returnX = m.width - m.sideMargin - m.returnWidth
        let end = returnX - m.keyGap
        // The field's own keys, right of the space bar (or in its place), on the letters layer only.
        let fieldKeys: [String]
        switch (layer, field) {
        case (.letters, .email): fieldKeys = ["@", "."]
        case (.letters, .webSearch): fieldKeys = ["."]
        case (.letters, .url): fieldKeys = [".", "/", dotCom]
        default: fieldKeys = []
        }
        if layer == .letters, field == .url {
            // No space bar, as on Apple's URL keyboard: the three keys share its room.
            let count = Double(fieldKeys.count)
            let width = (end - x - (count - 1) * m.keyGap) / count
            for (index, text) in fieldKeys.enumerated() {
                add(.character(text), text, x: x + Double(index) * (width + m.keyGap), row: 3, width: width)
            }
        } else {
            let fieldWidth = Double(fieldKeys.count) * (m.letterWidth + m.keyGap)
            add(.space, "space", x: x, row: 3, width: max(end - fieldWidth - x, 1))
            for (index, text) in fieldKeys.enumerated() {
                add(.character(text), text, x: end - fieldWidth + m.keyGap + Double(index) * (m.letterWidth + m.keyGap),
                    row: 3, width: m.letterWidth)
            }
        }
        add(.returnKey, "", x: returnX, row: 3, width: m.returnWidth)
        return keys
    }

    /// The emoji panel's keys: the layer key back to letters ("ABC") and the globe at the left of the bottom row and
    /// delete at its right, where they are on the letters layer.
    private static func emojiKeys(metrics m: KeyboardMetrics, showsGlobe: Bool) -> [PlacedKey] {
        func key(_ action: KeyAction, _ label: String, x: Double) -> PlacedKey {
            PlacedKey(action: action, frame: KeyRect(x: x, y: m.rowY(3), width: m.wideWidth, height: m.rowHeight), label: label)
        }
        var keys = [key(.layer(.letters), "ABC", x: m.sideMargin)]
        if showsGlobe { keys.append(key(.nextKeyboard, "", x: m.sideMargin + m.wideWidth + m.keyGap)) }
        keys.append(key(.delete, "", x: m.width - m.sideMargin - m.wideWidth))
        return keys
    }

    /// The emoji panel's scrolling grid: the whole key area above the bottom row, to half the row gap above it.
    static func emojiGridFrame(metrics m: KeyboardMetrics) -> KeyRect {
        KeyRect(x: 0, y: 0, width: m.width, height: m.rowY(3) - m.rowGap / 2)
    }

    /// The emoji panel's category jump bar: between its left keys and delete, from the grid down to the bottom, so
    /// no point of the panel goes to a key far from it.
    static func emojiJumpBarFrame(metrics m: KeyboardMetrics, showsGlobe: Bool) -> KeyRect {
        let left = m.sideMargin + Double(showsGlobe ? 2 : 1) * (m.wideWidth + m.keyGap)
        let right = m.width - m.sideMargin - m.wideWidth - m.keyGap
        let top = emojiGridFrame(metrics: m).maxY
        return KeyRect(x: left, y: top, width: max(right - left, 0), height: m.height - top)
    }

    /// The distance between neighbouring top-row letter (a–z) centres, or nil without two of them: on the letters
    /// layer, a letter width plus a key gap; the other layers have no letters.
    static func letterPitch(in keys: [PlacedKey]) -> Double? {
        let letters = keys.filter { $0.action.letterIndex != nil }
        guard let top = letters.map(\.frame.y).min() else { return nil }
        let centres = letters.filter { $0.frame.y == top }.map(\.frame.midX).sorted()
        guard centres.count >= 2, let first = centres.first, let last = centres.last, last > first else { return nil }
        return (last - first) / Double(centres.count - 1)
    }

    /// A point outside the space bar counts as this much farther from it (points): the biggest key gets the
    /// least of the gaps around it (ARCHITECTURE.md, "A stricter space bar").
    static let spaceMissPenalty: Double = 8
    /// The delete key's frame reaches this much further left, towards M, for the nearest key (points)
    /// (ARCHITECTURE.md, "A wider delete key").
    static let deleteReachLeft: Double = 8

    /// The key under a touch, or the nearest one, so gaps between keys are never dead. Distances are to the
    /// frame (the delete key's reaching `deleteReachLeft` further left), the space bar's plus
    /// `spaceMissPenalty` outside it; ties go to the nearer center, then the earlier key.
    static func nearestKey(toX x: Double, y: Double, in keys: [PlacedKey]) -> Int? {
        var best: (index: Int, distance: Double, center: Double)?
        for (index, key) in keys.enumerated() {
            var frame = key.frame
            if key.action == .delete {
                frame.x -= deleteReachLeft
                frame.width += deleteReachLeft
            }
            var distance = frame.distanceSquared(toX: x, y: y)
            if key.action == .space, distance > 0 {
                let penalized = distance.squareRoot() + spaceMissPenalty
                distance = penalized * penalized
            }
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
