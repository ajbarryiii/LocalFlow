import Foundation

/// Where an adjustment the keyboard issued should leave the caret, as the text right around it:
/// the outcome a host callback must show to count as the keyboard's own (ARCHITECTURE.md, "Undo
/// ownership v2": consumable expectations, never time windows). Held only while the adjustment is
/// pending, in memory.
struct CaretExpectation: Equatable, Sendable {
    /// Code units expected right before the caret, nearest last; nil when nothing is known.
    var before: [UInt16]?
    /// Code units expected right after the caret; nil when nothing is known.
    var after: [UInt16]?
    /// Characters the snapshot never showed between `before` and the caret: an edge probe jumped just
    /// past the snapshot's end, or a grapheme host's probe step ended beyond it.
    var hiddenBefore = 0
    /// Characters the snapshot never showed between the caret and `after`: the same past its start.
    var hiddenAfter = 0

    /// Up to this many code units on each side are compared.
    static let window = 32

    /// The caret at UTF-16 `split` of `units`.
    init(units: [UInt16], split: Int) {
        let split = min(max(split, 0), units.count)
        before = Array(units[max(0, split - Self.window) ..< split])
        after = Array(units[split ..< min(units.count, split + Self.window)])
    }

    init(before: [UInt16]?, after: [UInt16]?, hiddenBefore: Int = 0, hiddenAfter: Int = 0) {
        self.before = before
        self.after = after
        self.hiddenBefore = hiddenBefore
        self.hiddenAfter = hiddenAfter
    }

    /// Whether a host context fits: on each side, the text both show is the same. A side the host
    /// shows nothing of cannot disagree; but when neither side can be compared, the expectation fits
    /// only if both agree on which sides are empty, unless something it expects is unknown.
    func matches(before hostBefore: String, after hostAfter: String) -> Bool {
        let visibleBefore = hostBefore.dropLast(hiddenBefore)
        let visibleAfter = hostAfter.dropFirst(hiddenAfter)
        let hostBeforeUnits = Array(visibleBefore.utf16.suffix(Self.window))
        let hostAfterUnits = Array(visibleAfter.utf16.prefix(Self.window))
        var compared = 0
        if let before {
            let n = min(before.count, hostBeforeUnits.count)
            guard before.suffix(n).elementsEqual(hostBeforeUnits.suffix(n)) else { return false }
            compared += n
        }
        if let after {
            let m = min(after.count, hostAfterUnits.count)
            guard after.prefix(m).elementsEqual(hostAfterUnits.prefix(m)) else { return false }
            compared += m
        }
        if compared > 0 { return true }
        if before == nil || after == nil || hiddenBefore > 0 || hiddenAfter > 0 { return true }
        return before?.isEmpty == hostBeforeUnits.isEmpty && after?.isEmpty == hostAfterUnits.isEmpty
    }
}
