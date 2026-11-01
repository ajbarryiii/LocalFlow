import Foundation

/// The dictation island's three forms (ARCHITECTURE.md, "Top row"): the compact Start, the recording grown across the
/// bar (the whole island is Stop), and the short pill of the wait for the transcript.
enum IslandForm: Equatable, Sendable {
    case compact, expanded, processing
}

/// Where the top row's parts go for an island form (ARCHITECTURE.md, "Top row"), left to right inside the bar's
/// padding: the menu button, the middle (status, chips, candidates), Cancel while a dictation is in progress, and the
/// island, whose right end never moves. While recording the island stays under half the bar (round 9, owner), with
/// Cancel beside it in the bar's right half, in reach of a right thumb, a clear gap from Stop. Cancel's place is the
/// recording's, so it never moves once shown (round 5): when the wait contracts the island, the middle takes the room
/// between Cancel and the short pill. Left-handed (round 10, owner), every part is reflected across the bar's middle:
/// the island at the left end, growing rightwards, Cancel on its right in a left thumb's reach, the menu button at the
/// right end. Each part is a horizontal span in the bar's coordinates; all are the control height tall. Pure.
struct IslandLayout: Equatable, Sendable {
    struct Span: Equatable, Sendable {
        var x: Double
        var width: Double
        var maxX: Double { x + width }
    }

    static let padding = 8.0
    static let spacing = 8.0
    /// Between Cancel and the recording island: Cancel discards the dictation, so a near miss for Stop must not reach it.
    static let cancelGap = 12.0
    /// How far right of the bar's middle Cancel's centre sits at least: in the right half, where a right thumb is.
    static let cancelOffset = 4.0
    /// The recording island's widest, in a wide (landscape) bar.
    static let maximumExpandedWidth = 200.0

    var menu: Span
    var cancel: Span?
    var middle: Span
    var island: Span

    /// Cancel's circle, a little smaller than the bar's controls (its tap area is wider, `KeyboardMetrics.cancelTapArea`).
    static func cancelWidth(controlHeight: Double) -> Double { controlHeight - 6 }

    /// The wait's short pill: room for its shimmer and no more (round 10, Opus: 1.5 times its height held 6 dots, now 8).
    static func processingWidth(controlHeight: Double) -> Double { controlHeight * 1.9 }

    /// Start's width with a `labelWidth` "Start" beside the mark: its padding, the 19-point mark and the gap, never
    /// narrower than 2.4 times its height (the capsule's width before the island).
    static func startWidth(labelWidth: Double, controlHeight: Double) -> Double {
        max(controlHeight * 2.4, 14 + 19 + 6 + labelWidth + 14)
    }

    /// The recording island's width in a bar `barWidth` points wide: as wide as leaves Cancel, beside it, in the bar's
    /// right half, so always under half the bar, and no wider than `maximumExpandedWidth`.
    static func expandedWidth(barWidth: Double, controlHeight: Double) -> Double {
        let room = barWidth / 2 - padding - cancelGap - cancelWidth(controlHeight: controlHeight) / 2 - cancelOffset
        return max(min(room.rounded(.down), maximumExpandedWidth), 0)
    }

    /// The parts in a bar `barWidth` points wide whose controls are `controlHeight` tall, for an island `form` whose
    /// compact width is `startWidth`, reflected when `leftHanded`. In a bar too narrow for everything the middle goes first,
    /// then the island shrinks.
    init(barWidth: Double, controlHeight: Double, startWidth: Double, form: IslandForm, leftHanded: Bool = false) {
        self.init(rightHanded: barWidth, controlHeight: controlHeight, startWidth: startWidth, form: form)
        guard leftHanded else { return }
        func mirrored(_ span: Span) -> Span { Span(x: barWidth - span.maxX, width: span.width) }
        menu = mirrored(menu)
        middle = mirrored(middle)
        island = mirrored(island)
        cancel = cancel.map(mirrored)
    }

    private init(rightHanded barWidth: Double, controlHeight: Double, startWidth: Double, form: IslandForm) {
        let end = barWidth - Self.padding
        menu = Span(x: Self.padding, width: controlHeight)
        let next = menu.maxX + Self.spacing
        guard form != .compact else {
            cancel = nil
            island = Span(x: end - min(startWidth, max(end - next, 0)), width: min(startWidth, max(end - next, 0)))
            middle = Span(x: next, width: max(island.x - Self.spacing - next, 0))
            return
        }
        let cancelWidth = Self.cancelWidth(controlHeight: controlHeight)
        let recording = min(Self.expandedWidth(barWidth: barWidth, controlHeight: controlHeight),
                            max(end - next - cancelWidth - Self.cancelGap, 0))
        let cancel = Span(x: end - recording - Self.cancelGap - cancelWidth, width: cancelWidth)
        self.cancel = cancel
        if form == .expanded {
            island = Span(x: end - recording, width: recording)
            middle = Span(x: next, width: max(cancel.x - Self.spacing - next, 0))
        } else {
            let width = min(Self.processingWidth(controlHeight: controlHeight), recording)
            island = Span(x: end - width, width: width)
            middle = Span(x: cancel.maxX + Self.spacing, width: max(island.x - Self.spacing - cancel.maxX - Self.spacing, 0))
        }
    }
}
