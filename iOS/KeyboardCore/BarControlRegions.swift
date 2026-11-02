import Foundation

/// Where the dictation bar's controls are, in the bar's coordinates (ARCHITECTURE.md, "Reach above the keys"):
/// each control's frame as last laid out, plus, for `linger` seconds after a control moved or went, the frame
/// it left. Reported frames are the destination layout, while the bar animates its controls there, so a
/// control still visible where it was stays the bar's. When a recording ends, the island's former area takes no tap for
/// `stopGuard` (round 11): Cancel slides into it with the contracting island, and a quick second tap on Stop must
/// neither cancel nor type. Pure.
struct BarControlRegions: Equatable, Sendable {
    /// Longer than the bar's animations: its chips over 0.2 s, the Start capsule with a spring.
    static let linger: TimeInterval = 0.6

    private struct Left: Equatable, Sendable {
        var rect: KeyRect
        var until: TimeInterval
    }

    private var current: [String: KeyRect] = [:]
    private var left: [String: Left] = [:]
    /// How long after a recording ends Stop's former area takes no tap and Cancel ignores taps: a double tap's second
    /// tap, or one the user thinks did not register, and longer than Cancel's slide beside the wait's pill.
    static let stopGuard: TimeInterval = 0.45
    /// The island's former area while the guard holds: Stop's tap area as it was, widened to the island's frame.
    private var guarded: Left?
    /// When the guard after the last recording's end ends.
    private var guardUntil = -TimeInterval.infinity

    /// The control `id` is now at `rect`, or gone (nil).
    mutating func set(_ id: String, _ rect: KeyRect?, now: TimeInterval) {
        guard current[id] != rect else { return }
        if let old = current[id] { left[id] = Left(rect: old, until: now + Self.linger) }
        current[id] = rect
    }

    /// The recording ended: Stop was tapped (called with the tap, before the bar moves), or the host ended it (called
    /// as the bar learns of it, when the island may already report the wait's frame). For `stopGuard` the island's
    /// former area (its frame as Stop, with its reach into the top row, and any frame it just left, widened to the
    /// island's frame) takes no tap, and Cancel ignores taps. Ending again while guarded only adds to the area.
    mutating func captureEnded(now: TimeInterval) {
        guardUntil = now + Self.stopGuard
        let frames = [current["start"], left["start"].flatMap { $0.until > now ? $0.rect : nil }, stopGuard(now: now)]
        guarded = frames.compactMap { $0 }.reduce(nil as KeyRect?) { union, frame in
            let inset = KeyboardMetrics.startHitInset
            let widened = KeyRect(x: frame.x - inset, y: frame.y, width: frame.width + 2 * inset, height: frame.height)
            guard let union else { return widened }
            let minX = min(union.x, widened.x), minY = min(union.y, widened.y)
            return KeyRect(x: minX, y: minY, width: max(union.maxX, widened.maxX) - minX,
                           height: max(union.maxY, widened.maxY) - minY)
        }.map { Left(rect: $0, until: guardUntil) }
    }

    /// The island's former area while the guard holds, in the bar's coordinates; nil otherwise.
    func stopGuard(now: TimeInterval) -> KeyRect? {
        guarded.flatMap { $0.until > now ? $0.rect : nil }
    }

    /// Whether Cancel acts on a tap now: not within `stopGuard` of a recording's end.
    func acceptsCancel(now: TimeInterval) -> Bool { now >= guardUntil }

    /// The control `id`'s frame now, without any it left.
    func frame(of id: String) -> KeyRect? { current[id] }

    /// Every control's frame now, the frames controls left less than `linger` ago, and Stop's guarded area.
    func rects(now: TimeInterval) -> [KeyRect] {
        Array(current.values) + left.values.filter { $0.until > now }.map(\.rect) + (stopGuard(now: now).map { [$0] } ?? [])
    }
}
