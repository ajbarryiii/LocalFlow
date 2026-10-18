import Foundation

/// Where the dictation bar's controls are, in the bar's coordinates (ARCHITECTURE.md, "Reach above the keys"):
/// each control's frame as last laid out, plus, for `linger` seconds after a control moved or went, the frame
/// it left. Reported frames are the destination layout, while the bar animates its controls there, so a
/// control still visible where it was stays the bar's. Pure.
struct BarControlRegions: Equatable, Sendable {
    /// Longer than the bar's animations: its chips over 0.2 s, the Start capsule with a spring.
    static let linger: TimeInterval = 0.6

    private struct Left: Equatable, Sendable {
        var rect: KeyRect
        var until: TimeInterval
    }

    private var current: [String: KeyRect] = [:]
    private var left: [String: Left] = [:]

    /// The control `id` is now at `rect`, or gone (nil).
    mutating func set(_ id: String, _ rect: KeyRect?, now: TimeInterval) {
        guard current[id] != rect else { return }
        if let old = current[id] { left[id] = Left(rect: old, until: now + Self.linger) }
        current[id] = rect
    }

    /// Every control's frame now, and the frames controls left less than `linger` ago.
    func rects(now: TimeInterval) -> [KeyRect] {
        Array(current.values) + left.values.filter { $0.until > now }.map(\.rect)
    }
}
