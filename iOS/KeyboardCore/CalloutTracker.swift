import Foundation

/// The key area's callout: the held character it was last drawn for, so it redraws only when the model's
/// callout (`KeyTouchModel.calloutTouch`) changes. Rebuilt keys (a layer, shift or size change) leave a drawn
/// callout over a key that moved or is gone, so the next update redraws or hides it whatever it showed: an
/// apostrophe from the numbers layer returns to letters at its release, and its callout must not stay behind.
struct CalloutTracker {
    struct Callout: Equatable {
        var touch: KeyTouchModel.TouchID
        var action: KeyAction
    }

    enum Change: Equatable {
        case show(Callout)
        case hide
    }

    private var drawn: Callout?
    private var stale = false

    /// The callout the model asks for now, nil for none: what to draw, or nil when the drawn callout already
    /// shows it.
    mutating func update(to callout: Callout?) -> Change? {
        guard stale || callout != drawn else { return nil }
        stale = false
        drawn = callout
        return callout.map(Change.show) ?? .hide
    }

    /// The keys were rebuilt: the next update draws or hides the callout.
    mutating func keysChanged() {
        stale = true
    }
}
