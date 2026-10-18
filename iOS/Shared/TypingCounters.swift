import Foundation

/// TestFlight-only typing counters (ARCHITECTURE.md, "Dropped taps: reach, skids and counters"): how often
/// each event happened, by the row and edge of the key nearest its touch-down point. Counts only; no text,
/// keys, positions or times. Remove before the first production release.
struct TypingCounters: Equatable, Sendable {
    enum Event: String, CaseIterable, Sendable {
        /// Every touch-down in the key area, ignored ones and those above the keys included.
        case touchDown
        /// A touch-down in the reach above the keys (the strip of the bar below its controls).
        case aboveKeys
        /// A touch-down handled at least 16, 50 or 100 ms after its timestamp (cumulative).
        case late16, late50, late100
        /// The system cancelled a touch that had not typed yet, or a swipe.
        case cancelled
        /// A touch-down ignored because a swipe was running.
        case ignored
        /// A touch became a swipe.
        case swipe
        /// A swipe typed as a tap.
        case skid
        /// A released swipe that decoded to no word.
        case swipeEmpty
        /// A tap soft key edges predicted; of those, one that typed another letter, or a space.
        case softTap, softLetter, softSpace
    }

    /// The row of the nearest key (`row1` at the top; lower rows count as `row4`), and `left` or `right`
    /// for the first or last key of its row.
    enum Region: String, CaseIterable, Sendable {
        case row1, row2, row3, row4, left, right

        static let rows: [Region] = [.row1, .row2, .row3, .row4]
    }

    /// Counts stop here, and larger stored values are ignored, so adding never overflows.
    static let maximumCount = 1_000_000_000

    /// `"event.region"` to a count, without zeros: the form stored in the App Group.
    private(set) var stored: [String: Int] = [:]

    init() {}

    /// Reads the stored form: entries with a known event and region and a whole count up to `maximumCount`;
    /// anything else is ignored.
    init(stored: [String: Any]?) {
        for (key, value) in stored ?? [:] {
            let parts = key.split(separator: ".", omittingEmptySubsequences: false)
            // A Bool also bridges to NSNumber; only a real number counts.
            guard parts.count == 2, Event(rawValue: String(parts[0])) != nil, Region(rawValue: String(parts[1])) != nil,
                  let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { continue }
            let double = number.doubleValue
            guard double.isFinite, double >= 1, double <= Double(Self.maximumCount), double == double.rounded() else { continue }
            self.stored[key] = Int(double)
        }
    }

    var isEmpty: Bool { stored.isEmpty }

    subscript(event: Event, region: Region) -> Int {
        stored[Self.key(event, region)] ?? 0
    }

    /// The event's count over all rows (edges are counted within them).
    func total(_ event: Event) -> Int {
        Region.rows.reduce(0) { $0 + self[event, $1] }
    }

    /// Counts the event once in each region (none without keys laid out).
    mutating func add(_ event: Event, regions: [Region]) {
        for region in regions { add(1, to: Self.key(event, region)) }
    }

    mutating func merge(_ other: TypingCounters) {
        for (key, count) in other.stored { add(count, to: key) }
    }

    private mutating func add(_ count: Int, to key: String) {
        stored[key] = min((stored[key] ?? 0) + count, Self.maximumCount)
    }

    private static func key(_ event: Event, _ region: Region) -> String { "\(event.rawValue).\(region.rawValue)" }
}
