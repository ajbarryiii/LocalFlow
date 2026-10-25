import Foundation

/// The remembered layout choices (`fieldLayoutOverrides`) as last read from the App Group
/// (ARCHITECTURE.md, "Field profiles"). The field is read at every host callback, so one reading is
/// reused until `invalidate()`: the keyboard calls it when it appears and after it writes a choice.
/// Names that are not a `FieldLayout` are dropped. Pure, in memory only.
struct FieldLayoutOverrideCache: Sendable {
    private var reading: [String: FieldLayout]?

    /// The cached reading, else a new one from `load` (nil when the App Group is unreachable, which
    /// reads as no choices).
    mutating func overrides(load: () -> [String: String]?) -> [String: FieldLayout] {
        if let reading { return reading }
        var parsed: [String: FieldLayout] = [:]
        for (key, value) in load() ?? [:] {
            if let layout = FieldLayout(rawValue: value) { parsed[key] = layout }
        }
        reading = parsed
        return parsed
    }

    /// The next `overrides` reads the App Group again.
    mutating func invalidate() {
        reading = nil
    }
}
