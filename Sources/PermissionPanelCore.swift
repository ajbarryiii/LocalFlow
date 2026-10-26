import CoreGraphics
import Foundation

// The "drag LocalFlow into the list" card for System Settings' Accessibility
// pane: where it docks, how it moves, and when a drop has played out. The
// windows, drag source and Settings tracking are in PermissionPanel.swift.
//
// Adapted from Scrawl's helper/PermissionPanel.swift
// (https://github.com/kitlangton/scrawl, MIT, Copyright (c) 2026 Kit Langton),
// which adapts its flight, Settings window tracking and drop race from
// AskForPermission (https://github.com/riko2chen/AskForPermission, MIT,
// Copyright (c) 2026 Riko). See Resources/Attribution.txt.

extension PrivacyPermission {
    /// Whether the permission's Settings list takes an app dragged into it.
    /// Microphone access is granted through Apple's prompt instead.
    var acceptsDraggedApp: Bool {
        switch self {
        case .microphone: return false
        case .accessibility: return true
        }
    }
}

enum PermissionPanel {
    /// The flight from the Grant Access button to the dock: critically
    /// damped, so the card leaves fast and decelerates into place.
    static let flightSpring = Spring(duration: 0.85, bounce: 0)
    /// Back to the button: exits run shorter than entrances.
    static let returnSpring = Spring(duration: 0.7, bounce: 0)
    /// Width leads height (and the path) by running on a shorter spring.
    static let widthLead = 0.78
    /// Peak height of the arc above the higher end, and its cap as a share of the distance.
    static let arcHeight: CGFloat = 160
    static let arcShare: CGFloat = 0.35
    /// Reduce Motion and the in-place exits: a fade with no travel.
    static let fadeDuration = 0.18

    // System Settings (macOS 26/27): a fixed 232 pt sidebar; the Privacy list
    // starts 20 pt past it and ends 20 pt before the window's right edge.
    static let settingsListLeading: CGFloat = 252
    static let settingsListTrailing: CGFloat = 20

    /// The step response of a spring from 0 to 1 at rest, by duration and
    /// bounce: ω = 2π / duration, ζ = 1 − bounce.
    struct Spring {
        let duration: Double
        let bounce: Double

        func value(_ t: Double) -> Double {
            guard t > 0 else { return 0 }
            let omega = 2 * Double.pi / duration
            let zeta = 1 - bounce
            if zeta >= 1 { return 1 - (1 + omega * t) * exp(-omega * t) }
            let damped = omega * (1 - zeta * zeta).squareRoot()
            return 1 - exp(-zeta * omega * t) * (cos(damped * t) + zeta * omega / damped * sin(damped * t))
        }

        /// Long enough that what's left is under a hundredth of a point on a screen-wide move.
        var settleTime: Double { duration * 1.8 }
    }

    /// Card metrics. The app row matches the Privacy list's column in the Settings window.
    struct Layout: Equatable {
        var rowWidth: CGFloat
        let instructionHeight: CGFloat = 28
        /// Less above the instruction than below the row: line height already pads the text.
        let top: CGFloat = 7
        let padding: CGFloat = 12
        let gutter: CGFloat = 52
        let rowHeight: CGFloat = 44
        let gap: CGFloat = 4
        let inset: CGFloat = 8
        let dockGap: CGFloat = 10
        /// Inside the window: this far above its bottom edge.
        let insideBottom: CGFloat = 20
        let radius: CGFloat = 18
        let rowRadius: CGFloat = 9
        let icon: CGFloat = 26
        let iconLeading: CGFloat = 10

        init(settingsWidth: CGFloat) {
            let column = settingsWidth - PermissionPanel.settingsListLeading - PermissionPanel.settingsListTrailing
            rowWidth = max(320, min(column, 640))
        }

        var textLeading: CGFloat { iconLeading + icon + 10 }
        var rowY: CGFloat { top + instructionHeight + gap }
        var cardSize: CGSize {
            CGSize(width: gutter + rowWidth + padding, height: rowY + rowHeight + padding)
        }
    }

    enum Dock: String { case below, inside, right, left, clamped }

    /// Where the card docks for a Settings window on a screen, both in AppKit
    /// coordinates (`visible` is the screen's `visibleFrame`). In order:
    /// - below the window, its app row under the Privacy list's column, if all of it fits;
    /// - inside the window's empty lower area (the lowest 30% of the pane
    ///   holds no rows), on the list's column and 20 pt above its bottom edge;
    /// - beside it, right then left;
    /// - else the below position pushed onto the screen.
    static func dock(settings: CGRect, visible: CGRect, layout: Layout) -> (frame: CGRect, dock: Dock) {
        let size = layout.cardSize
        let fits = { (r: CGRect) in
            r.minX >= visible.minX && r.maxX <= visible.maxX && r.minY >= visible.minY && r.maxY <= visible.maxY
        }
        let clampX = { (x: CGFloat) in min(max(x, visible.minX + 8), visible.maxX - size.width - 8) }
        let clampY = { (y: CGFloat) in min(max(y, visible.minY + 8), visible.maxY - size.height - 8) }
        // The list's column; nudged left if the card would pass the window's right edge.
        let column = min(settings.minX + settingsListLeading - layout.gutter, settings.maxX - layout.inset - size.width)
        let gap = layout.dockGap

        let below = CGRect(x: clampX(column), y: settings.minY - gap - size.height, width: size.width, height: size.height)
        if fits(below) { return (below, .below) }

        let insideY = max(settings.minY + layout.insideBottom, visible.minY + 8)
        let inside = CGRect(x: column, y: insideY, width: size.width, height: size.height)
        if fits(inside), inside.minX >= settings.minX, inside.maxY <= settings.minY + settings.height * 0.3 {
            return (inside, .inside)
        }

        let right = CGRect(x: settings.maxX + gap, y: clampY(settings.minY), width: size.width, height: size.height)
        if fits(right) { return (right, .right) }
        let left = CGRect(x: settings.minX - gap - size.width, y: clampY(settings.minY), width: size.width, height: size.height)
        if fits(left) { return (left, .left) }

        return (CGRect(x: clampX(below.minX), y: clampY(below.minY), width: size.width, height: size.height), .clamped)
    }

    /// CGWindow bounds (origin top-left of the primary screen) to AppKit's
    /// (origin bottom-left), and back.
    static func appKit(fromQuartz r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
    }

    static func quartz(fromAppKit r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
    }

    /// The flight's quadratic Bézier control point: midway across, `arcHeight`
    /// above the higher end (less on short hops), and no higher than `ceiling`
    /// so the card stays on screen.
    static func flightControl(source: CGRect, target: CGRect, ceiling: CGFloat) -> CGPoint {
        let distance = hypot(target.midX - source.midX, target.midY - source.midY)
        let lift = min(arcHeight, distance * arcShare)
        let top = max(source.midY, target.midY)
        return CGPoint(x: (source.midX + target.midX) / 2, y: max(top, min(top + lift, ceiling)))
    }

    /// A drop is only a hint. Settings may ask to authenticate first, so the
    /// card steps aside until that sheet is dismissed (its window count drops
    /// below the highest seen since the drop) or 10 s pass, and the grant is
    /// then read again.
    struct DropRace {
        static let timeout: TimeInterval = 10
        let deadline: Date
        private(set) var peakWindowCount: Int

        init(droppedAt date: Date, settingsWindowCount: Int) {
            deadline = date.addingTimeInterval(Self.timeout)
            peakWindowCount = settingsWindowCount
        }

        /// Records the current Settings window count; true once the race is over.
        mutating func observe(settingsWindowCount count: Int, at date: Date) -> Bool {
            peakWindowCount = max(peakWindowCount, count)
            return count < peakWindowCount || date > deadline
        }
    }
}
