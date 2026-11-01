import Foundation

/// The dictation island's three forms (ARCHITECTURE.md, "Top row"): the compact Start, the recording grown across the
/// bar (the whole island is Stop), and the short pill of the wait for the transcript.
enum IslandForm: Equatable, Sendable {
    case compact, expanded, processing
}

/// Where the top row's parts go for an island form (ARCHITECTURE.md, "Top row"), left to right inside the bar's
/// padding: the menu button, Cancel while a dictation is in progress, the middle (status, chips, candidates), and the
/// island, whose right end never moves. Cancel sits beside the menu, so no change of the island's width moves it once
/// shown (round 5). Each part is a horizontal span in the bar's coordinates; all are the control height tall. Pure.
struct IslandLayout: Equatable, Sendable {
    struct Span: Equatable, Sendable {
        var x: Double
        var width: Double
        var maxX: Double { x + width }
    }

    static let padding = 8.0
    static let spacing = 8.0

    var menu: Span
    var cancel: Span?
    var middle: Span
    var island: Span

    /// Cancel's circle, a little smaller than the bar's controls.
    static func cancelWidth(controlHeight: Double) -> Double { controlHeight - 6 }

    /// The wait's short pill: room for its shimmer and no more.
    static func processingWidth(controlHeight: Double) -> Double { controlHeight * 1.9 }

    /// Start's width with a `labelWidth` "Start" beside the mark: its padding, the 19-point mark and the gap, never
    /// narrower than 2.4 times its height (the capsule's width before the island).
    static func startWidth(labelWidth: Double, controlHeight: Double) -> Double {
        max(controlHeight * 2.4, 14 + 19 + 6 + labelWidth + 14)
    }

    /// The parts in a bar `barWidth` points wide whose controls are `controlHeight` tall, for an island `form` whose
    /// compact width is `startWidth`. In a bar too narrow for everything the middle goes first, then the island shrinks.
    init(barWidth: Double, controlHeight: Double, startWidth: Double, form: IslandForm) {
        let end = barWidth - Self.padding
        menu = Span(x: Self.padding, width: controlHeight)
        var next = menu.maxX + Self.spacing
        if form == .compact {
            cancel = nil
        } else {
            let cancel = Span(x: next, width: Self.cancelWidth(controlHeight: controlHeight))
            self.cancel = cancel
            next = cancel.maxX + Self.spacing
        }
        let room = max(end - next, 0)
        let width: Double
        switch form {
        case .compact: width = min(startWidth, room)
        case .expanded: width = room
        case .processing: width = min(Self.processingWidth(controlHeight: controlHeight), room)
        }
        island = Span(x: end - width, width: width)
        middle = Span(x: next, width: max(island.x - Self.spacing - next, 0))
    }
}
