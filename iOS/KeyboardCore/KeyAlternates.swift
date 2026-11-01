import Foundation

/// Press-and-hold alternates, after Apple's keyboard (ARCHITECTURE.md, "Press-and-hold alternates"): holding a key
/// that has them for `holdDelay` opens a row of choices above it, the key's own character first, over the key. The
/// finger slides to pick one and lifts to type it; a finger that never moved `moveSlop` types the key's own
/// character, as a tap would. Pure.
enum KeyAlternates {
    /// How long a character key is held before its alternates open.
    static let holdDelay: TimeInterval = 0.4
    /// How far (points, sideways) the finger moves from where the row opened before it picks by position.
    static let moveSlop: Double = 6
    /// The gap between the key and the row above it, as for the key callout.
    static let gap: Double = 4
    /// The row keeps this far inside the key area's sides.
    static let margin: Double = 2
    /// The width of a cell in a row with a domain (or any option longer than one character): room for ".com", and
    /// narrow enough that the row starts over its key on a 375-point phone.
    static let domainCellWidth: Double = 44

    /// The domain endings, as on Apple's keyboard: the URL field's ".com" key and the web search field's "." offer them.
    static let domains = [KeyboardLayout.dotCom, ".org", ".net", ".edu", ".us"]

    /// The alternates of a key's character (lowercase for letters) in a field, without the character itself; empty for
    /// none. `field` is the letters layer's field (`.standard` on the other layers): in a web search field (Safari's
    /// address bar) the "." beside the space bar offers the domains.
    static func alternates(for character: String, field: KeyboardField = .standard) -> [String] {
        if field == .webSearch, character == "." { return domains }
        return table[character] ?? []
    }

    /// VoiceOver's route to a key's alternates: what its custom actions type, in the row's order, the key's own
    /// character excluded (activating the key types it). The field's own alternates on the letters layer only, as
    /// the row shows them (`KeyTouchModel.alternateOptions`).
    static func accessibilityActions(for character: String, layer: KeyboardLayer, field: KeyboardField) -> [String] {
        alternates(for: character, field: layer == .letters ? field : .standard)
    }

    /// What the row shows for a key: its own character, then its alternates; empty when it has none.
    static func options(for character: String, field: KeyboardField = .standard) -> [String] {
        let more = alternates(for: character, field: field)
        return more.isEmpty ? [] : [character] + more
    }

    private static let table: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "s": ["ß", "ś", "š"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        "-": ["–", "—", "•"],
        ".": ["…"],
        "'": ["’", "‘", "`"],
        "\"": ["“", "”", "„", "«", "»"],
        "$": ["€", "£", "¥", "¢", "₩"],
        "?": ["¿"],
        "!": ["¡"],
        "&": ["§"],
        "%": ["‰"],
        "/": ["\\"],
        "0": ["°"],
        KeyboardLayout.dotCom: Array(domains.dropFirst()),
    ]

    /// The row's cells for `options` of the key at `key`, in a key area `width` wide: `frames(count:key:width:cell:)`
    /// with cells as wide as the key, or `domainCellWidth` when an option is longer than one character.
    static func frames(options: [String], key: KeyRect, width: Double) -> [KeyRect] {
        frames(count: options.count, key: key, width: width,
               cell: options.contains { $0.count > 1 } ? domainCellWidth : key.width)
    }

    /// The row's cells for `count` options of the key at `key`, in a key area `width` wide: one row `gap` above the
    /// key, cells `cell` wide (the key's width by default; narrower when they would not fit), the first centred over
    /// the key and the rest running towards the middle of the keyboard (right from the left half, left from the right
    /// half), the whole row moved inside the area's sides when it would cross one.
    static func frames(count: Int, key: KeyRect, width: Double, cell: Double? = nil) -> [KeyRect] {
        guard count > 0 else { return [] }
        let cell = min(cell ?? key.width, (width - 2 * margin) / Double(count))
        let direction: Double = key.midX <= width / 2 ? 1 : -1
        let first = key.midX - cell / 2
        var xs = (0 ..< count).map { first + direction * Double($0) * cell }
        let low = xs.min() ?? 0, high = (xs.max() ?? 0) + cell
        let shift = low < margin ? margin - low : (high > width - margin ? width - margin - high : 0)
        xs = xs.map { $0 + shift }
        let y = key.y - gap - key.height
        return xs.map { KeyRect(x: $0, y: y, width: cell, height: key.height) }
    }

    /// The cell the finger is over at `x`: the one containing it, else the nearest end.
    static func index(atX x: Double, in frames: [KeyRect]) -> Int {
        var best = 0, bestDistance = Double.infinity
        for (index, frame) in frames.enumerated() {
            let distance = max(frame.x - x, 0, x - frame.maxX)
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }
}
