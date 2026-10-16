import Foundation

/// The key area's touch tracking without UIKit: the key under each finger, what to type and when,
/// rollover order, the space bar's hold, the hand-off to trackpad mode, and swipe gestures. Pure.
///
/// - Keys are tracked by action, never by index, and every rebuild (a layer or shift change)
///   remaps held function-key and slide fingers onto the new keys or drops them, so such a finger can
///   never point at a key that no longer exists. A held character keeps the key it touched down on.
/// - Rollover: a new finger first commits every key still held by earlier fingers, in press order:
///   characters, space, return and slides alike. A committed space no longer becomes the trackpad.
/// - Characters type at release (or rollover), the key nearest the touch-down point, never hit-tested
///   again: a tap that rolls onto space, delete or Shift still types its own key, and a cancelled one
///   types nothing. Shift and layer keys act on touch-down; space, return and slides from a layer key
///   type on lift (or rollover); delete starts repeating on touch-down (ARCHITECTURE.md, "Typing model
///   v4 and swipe typing", amending "Typing model v3"). Every key's touch-down first ends trackpad
///   settlement (`keyDown`).
/// - Swipe: with `swipeEnabled`, on the letters layer, an uncommitted character touch that is the only
///   finger and moves `swipeThreshold` from its touch-down point becomes a swipe. It types nothing, its
///   callout ends, other touches are ignored until it ends, and its release emits its samples (`swipe`);
///   a cancelled swipe emits nothing.
/// - Each finger keeps the field the keyboard served when it touched down (or, touched down before any
///   identity, the first one identified after); what it types carries that field, so the keyboard can
///   refuse it in another identified one (ARCHITECTURE.md, "Typing model v2"). A change to another
///   identified field drops held, uncommitted keys and a running swipe.
struct KeyTouchModel: Equatable, Sendable {
    typealias TouchID = Int

    enum Role: Equatable, Sendable {
        case character, space, delete, returnKey, shift, layer
        /// Started on a layer key and moved onto a character: types it, then returns to letters.
        case slide
    }

    struct Touch: Equatable, Sendable {
        var id: TouchID
        var role: Role
        /// The key the finger acts on: for a character, the key it touched down on; for the rest, the key
        /// under the finger now (nil when it is over no key).
        var action: KeyAction?
        var startX: Double
        var startY: Double
        var x: Double
        var y: Double
        var committed = false
        /// The space bar moved past the slop: this touch can no longer become the trackpad.
        var holdCancelled = false
        /// The field the keyboard served at touch-down.
        var field: UUID?
        /// The finger's path while it may still become a swipe (from its touch-down point); empty otherwise.
        var samples: [SwipeSample] = []
    }

    enum Effect: Equatable, Sendable {
        /// A key touched down (any key but the globe): trackpad settlement ends now, before whatever the
        /// key does at once or at its release (ARCHITECTURE.md, "Typing model v2").
        case keyDown
        /// `field`: the field the finger touched down in (nil for keys acting at once).
        case type(KeyAction, field: UUID? = nil)
        case beginDelete
        /// `cancelled`: the system cancelled the touch (or the key area dropped it), which is not a
        /// release: a cancelled tap deletes nothing.
        case endDelete(cancelled: Bool)
        case startHoldTimer(TouchID)
        case cancelHoldTimer(TouchID)
        case beginTrackpad
        /// `cancelled` is a system cancellation, not a lift.
        case endTrackpad(cancelled: Bool)
        /// A swipe was released: its samples from the touch-down point through the lift, and the field it
        /// touched down in (ARCHITECTURE.md, "Typing model v4 and swipe typing").
        case swipe([SwipeSample], field: UUID?)
    }

    var parameters = TrackpadParameters.standard
    /// Whether a drag on a letter may become a swipe: true only while the swipe engine is loaded and the
    /// field is not secure text entry.
    var swipeEnabled = false
    private(set) var keys: [PlacedKey] = []
    private(set) var layer = KeyboardLayer.letters
    /// Held fingers in press order.
    private(set) var touches: [Touch] = []
    private(set) var trackpadTouch: TouchID?
    /// The field the trackpad's finger touched down in.
    private(set) var trackpadField: UUID?
    /// The movement from its touch-down point that turns a letter touch into a swipe: half a letter-key
    /// pitch, `(letterWidth + keyGap) / 2`, from the letter keys last laid out (infinite before any).
    private(set) var swipeThreshold = Double.infinity
    private(set) var swipeTouch: TouchID?
    /// The field the swipe's finger touched down in.
    private(set) var swipeField: UUID?
    /// The running swipe's samples so far.
    private(set) var swipeSamples: [SwipeSample] = []

    var isTrackpadActive: Bool { trackpadTouch != nil }
    var isSwipeActive: Bool { swipeTouch != nil }

    /// Keys drawn pressed: held function keys (space, delete, return, shift, layer keys).
    var pressedActions: Set<KeyAction> {
        Set(touches.compactMap { touch in
            guard !touch.committed, touch.role != .character, touch.role != .slide else { return nil }
            return touch.action
        })
    }

    /// The finger whose character a callout shows: the newest held character, committed or not, or still
    /// sliding. A swipe shows none.
    var calloutTouch: Touch? {
        touches.last { touch in
            guard touch.action?.isCharacter == true else { return false }
            return touch.role == .character || (touch.role == .slide && !touch.committed)
        }
    }

    /// The character to show in a callout (`calloutTouch`).
    var calloutAction: KeyAction? { calloutTouch?.action }

    /// Whether the touch's moves should bring every coalesced sample (`moved(_:x:y:t:coalesced:)`): it is
    /// a swipe, or may still become one.
    func collectsSamples(_ id: TouchID) -> Bool {
        id == swipeTouch || touches.contains { $0.id == id && !$0.samples.isEmpty }
    }

    // MARK: Events

    /// `t`: the touch's timestamp in seconds. `field`: the field the keyboard serves at this touch-down.
    mutating func began(_ id: TouchID, x: Double, y: Double, t: TimeInterval = 0, field: UUID? = nil) -> [Effect] {
        guard trackpadTouch == nil, swipeTouch == nil, let action = nearestAction(x: x, y: y) else { return [] }
        // The globe is a UIKit button with its own touches; a touch that lands near it is ignored.
        if action == .nextKeyboard { return commitPending() }
        var effects: [Effect] = [.keyDown] + commitPending()
        var touch = Touch(id: id, role: .character, action: action, startX: x, startY: y, x: x, y: y, field: field)
        switch action {
        case .character:
            // Typed at release or rollover (v4); a possible swipe until then.
            if swipeEnabled, layer == .letters { touch.samples = [SwipeSample(x: x, y: y, t: t)] }
        case .nextKeyboard:
            break
        case .space:
            touch.role = .space
            effects.append(.startHoldTimer(id))
        case .delete:
            touch.role = .delete
            effects.append(.beginDelete)
        case .returnKey:
            touch.role = .returnKey
        case .shift:
            touch.role = .shift
            effects.append(.type(.shift))
        case .layer:
            touch.role = .layer
            effects.append(.type(action))
        }
        touches.append(touch)
        return effects
    }

    /// `x`, `y`, `t`: where the finger is now, and when. `coalesced`: every touch sample of this move in
    /// order (the last one where the finger is now), for a touch that `collectsSamples`; empty counts the
    /// current position alone.
    mutating func moved(_ id: TouchID, x: Double, y: Double, t: TimeInterval = 0, coalesced: [SwipeSample] = []) -> [Effect] {
        let samples = coalesced.isEmpty ? [SwipeSample(x: x, y: y, t: t)] : coalesced
        if id == swipeTouch {
            swipeSamples += samples
            return []
        }
        guard id != trackpadTouch, let index = touches.firstIndex(where: { $0.id == id }) else { return [] }
        touches[index].x = x
        touches[index].y = y
        let touch = touches[index]
        guard !touch.committed else { return [] }
        switch touch.role {
        case .space:
            let dx = x - touch.startX, dy = y - touch.startY
            if abs(dx) >= parameters.dragActivationDistance { return beginTrackpad(index) }
            // Measured: up to 16 pt from the touch-down point (straight line) still activates at the timer.
            if !touch.holdCancelled, (dx * dx + dy * dy).squareRoot() > parameters.holdSlop {
                touches[index].holdCancelled = true
                return [.cancelHoldTimer(id)]
            }
        case .character:
            // The key stays the one touched down on; the path counts only towards a swipe.
            guard !touch.samples.isEmpty else { break }
            touches[index].samples += samples
            let dx = x - touch.startX, dy = y - touch.startY
            if swipeEnabled, layer == .letters, touches.count == 1, trackpadTouch == nil,
               (dx * dx + dy * dy).squareRoot() >= swipeThreshold {
                beginSwipe(index)
            }
        case .slide, .layer:
            let action = nearestAction(x: x, y: y)
            guard action != touch.action else { break }
            touches[index].action = action
            if touch.role == .layer, action?.isCharacter == true { touches[index].role = .slide }
        case .delete, .returnKey, .shift:
            break
        }
        return []
    }

    /// `x`, `y`, `t`: where the finger lifted, and when. A swipe's trajectory runs through the release: the
    /// lift is its last sample, unless it repeats the last one exactly.
    mutating func ended(_ id: TouchID, x: Double, y: Double, t: TimeInterval = 0) -> [Effect] {
        if id == trackpadTouch {
            trackpadTouch = nil
            return [.endTrackpad(cancelled: false)]
        }
        if id == swipeTouch {
            var samples = swipeSamples
            let lift = SwipeSample(x: x, y: y, t: t)
            if samples.last != lift { samples.append(lift) }
            let field = swipeField
            endSwipe()
            return [.swipe(samples, field: field)]
        }
        guard let index = touches.firstIndex(where: { $0.id == id }) else { return [] }
        let touch = touches.remove(at: index)
        var effects: [Effect] = []
        switch touch.role {
        case .character, .slide:
            guard !touch.committed, let action = touch.action, action.isCharacter else { break }
            effects.append(.type(action, field: touch.field))
            // A number slid to from the layer key returns to letters, as on Apple's keyboard.
            if touch.role == .slide, layer != .letters { effects.append(.type(.layer(.letters))) }
        case .space:
            effects.append(.cancelHoldTimer(id))
            // Measured: a drag that never became the trackpad (a fast one, or one past the slop) types a space.
            if !touch.committed { effects.append(.type(.space, field: touch.field)) }
        case .returnKey:
            if !touch.committed, nearestAction(x: x, y: y) == .returnKey { effects.append(.type(.returnKey, field: touch.field)) }
        case .delete:
            effects.append(.endDelete(cancelled: false))
        case .shift, .layer:
            break
        }
        return effects
    }

    /// The system cancelled the touch: a cancellation, not a release. A held character or a swipe types
    /// nothing.
    mutating func cancelled(_ id: TouchID) -> [Effect] {
        if id == trackpadTouch {
            trackpadTouch = nil
            return [.endTrackpad(cancelled: true)]
        }
        if id == swipeTouch {
            endSwipe()
            return []
        }
        guard let index = touches.firstIndex(where: { $0.id == id }) else { return [] }
        return release(touches.remove(at: index))
    }

    /// The space bar's hold timer fired.
    mutating func holdElapsed(_ id: TouchID) -> [Effect] {
        guard trackpadTouch == nil, let index = touches.firstIndex(where: { $0.id == id }),
              touches[index].role == .space, !touches[index].committed, !touches[index].holdCancelled else { return [] }
        return beginTrackpad(index)
    }

    /// The keys were rebuilt (a layer or shift change, or a new size). Held slides and layer-key fingers
    /// follow the keys under them; a held character keeps its key; a finger whose function key is gone is
    /// dropped. Letter keys set the swipe threshold.
    mutating func keysChanged(_ keys: [PlacedKey], layer: KeyboardLayer) -> [Effect] {
        self.keys = keys
        self.layer = layer
        if layer == .letters, let threshold = Self.swipeThreshold(in: keys) { swipeThreshold = threshold }
        var effects: [Effect] = []
        var kept: [Touch] = []
        for var touch in touches {
            if touch.committed {
                kept.append(touch)
                continue
            }
            switch touch.role {
            case .character:
                kept.append(touch)
            case .slide, .layer:
                touch.action = nearestAction(x: touch.x, y: touch.y)
                kept.append(touch)
            case .space, .delete, .returnKey, .shift:
                if let action = touch.action, keys.contains(where: { $0.action == action }) {
                    kept.append(touch)
                } else {
                    effects += release(touch)
                }
            }
        }
        touches = kept
        return effects
    }

    /// Another field became current (`field`, ARCHITECTURE.md, "Typing model v2"): fingers that touched
    /// down before any identity bind to this field; uncommitted ones bound to a different identified field
    /// end without typing (held characters and a swipe included, v4); the rest go on. Nothing changes while
    /// no field is identified.
    mutating func fieldChanged(to field: UUID?) -> [Effect] {
        guard let field else { return [] }
        var effects: [Effect] = []
        if trackpadTouch != nil {
            if let bound = trackpadField, bound != field {
                trackpadTouch = nil
                effects.append(.endTrackpad(cancelled: true))
            } else {
                trackpadField = field
            }
        }
        if swipeTouch != nil {
            if let bound = swipeField, bound != field {
                endSwipe()
            } else {
                swipeField = field
            }
        }
        var kept: [Touch] = []
        for var touch in touches {
            if !touch.committed, let bound = touch.field, bound != field {
                effects += release(touch)
            } else {
                if touch.field == nil { touch.field = field }
                kept.append(touch)
            }
        }
        touches = kept
        return effects
    }

    /// Ends every touch, for example when the keyboard disappears. Nothing is typed and no swipe is emitted.
    mutating func cancelAll() -> [Effect] {
        var effects: [Effect] = []
        if trackpadTouch != nil {
            trackpadTouch = nil
            effects.append(.endTrackpad(cancelled: true))
        }
        endSwipe()
        for touch in touches { effects += release(touch) }
        touches = []
        return effects
    }

    // MARK: Helpers

    private func nearestAction(x: Double, y: Double) -> KeyAction? {
        KeyboardLayout.nearestKey(toX: x, y: y, in: keys).map { keys[$0].action }
    }

    /// Half the pitch of the top row's letter keys, or nil without two of them.
    private static func swipeThreshold(in keys: [PlacedKey]) -> Double? {
        let letters = keys.filter { $0.action.isCharacter }
        guard let top = letters.map(\.frame.y).min() else { return nil }
        let centers = letters.filter { $0.frame.y == top }.map(\.frame.midX).sorted()
        guard centers.count >= 2, let first = centers.first, let last = centers.last, last > first else { return nil }
        return (last - first) / Double(centers.count - 1) / 2
    }

    /// Rollover: commits every earlier finger's key, in press order.
    private mutating func commitPending() -> [Effect] {
        var effects: [Effect] = []
        for index in touches.indices where !touches[index].committed {
            let touch = touches[index]
            switch touch.role {
            case .character, .slide:
                guard let action = touch.action, action.isCharacter else { continue }
                effects.append(.type(action, field: touch.field))
            case .space:
                guard touch.action == .space else { continue }
                effects += [.cancelHoldTimer(touch.id), .type(.space, field: touch.field)]
            case .returnKey:
                guard touch.action == .returnKey else { continue }
                effects.append(.type(.returnKey, field: touch.field))
            case .delete, .shift, .layer:
                continue
            }
            touches[index].committed = true
            touches[index].samples = []
        }
        return effects
    }

    private mutating func beginTrackpad(_ index: Int) -> [Effect] {
        let touch = touches.remove(at: index)
        trackpadTouch = touch.id
        trackpadField = touch.field
        return [.cancelHoldTimer(touch.id), .beginTrackpad]
    }

    /// The finger leaves the keys: it types nothing, and other touches are ignored until it ends.
    private mutating func beginSwipe(_ index: Int) {
        let touch = touches.remove(at: index)
        swipeTouch = touch.id
        swipeField = touch.field
        swipeSamples = touch.samples
    }

    private mutating func endSwipe() {
        swipeTouch = nil
        swipeField = nil
        swipeSamples = []
    }

    /// Effects of dropping a held finger without typing: a cancellation, not a release.
    private func release(_ touch: Touch) -> [Effect] {
        switch touch.role {
        case .space: return [.cancelHoldTimer(touch.id)]
        case .delete: return [.endDelete(cancelled: true)]
        default: return []
        }
    }
}

extension KeyAction {
    var isCharacter: Bool {
        if case .character = self { return true }
        return false
    }
}
