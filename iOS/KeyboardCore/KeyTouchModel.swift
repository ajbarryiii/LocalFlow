import Foundation

/// The key area's touch tracking without UIKit: the key under each finger, what to type and when,
/// rollover order, the space bar's hold, and the hand-off to trackpad mode. Pure.
///
/// - Keys are tracked by action, never by index, and every rebuild (a layer or shift change)
///   remaps held fingers onto the new keys or drops them, so a held finger can never point at a
///   key that no longer exists.
/// - Rollover: a new finger first commits every key still held by earlier fingers, in press order:
///   characters, space and return alike. A committed space no longer becomes the trackpad.
/// - Characters, space and return type on lift (or rollover); shift and layer keys on touch-down;
///   delete starts repeating on touch-down.
/// - Each finger keeps the field the keyboard served when it touched down; what it types carries that
///   field, so the keyboard can refuse it in another one (ARCHITECTURE.md, "Typing correctness is
///   paramount").
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
        /// The key under the finger now; nil when it is over no key.
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
    }

    enum Effect: Equatable, Sendable {
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
    }

    var parameters = TrackpadParameters.standard
    private(set) var keys: [PlacedKey] = []
    private(set) var layer = KeyboardLayer.letters
    /// Held fingers in press order.
    private(set) var touches: [Touch] = []
    private(set) var trackpadTouch: TouchID?
    /// The field the trackpad's finger touched down in.
    private(set) var trackpadField: UUID?

    var isTrackpadActive: Bool { trackpadTouch != nil }

    /// Keys drawn pressed: held function keys (space, delete, return, shift, layer keys).
    var pressedActions: Set<KeyAction> {
        Set(touches.compactMap { touch in
            guard !touch.committed, touch.role != .character, touch.role != .slide else { return nil }
            return touch.action
        })
    }

    /// The character to show in a callout: the newest held, uncommitted character.
    var calloutAction: KeyAction? {
        touches.last { !$0.committed && ($0.role == .character || $0.role == .slide) && $0.action?.isCharacter == true }?.action
    }

    // MARK: Events

    /// `field`: the field the keyboard serves at this touch-down.
    mutating func began(_ id: TouchID, x: Double, y: Double, field: UUID? = nil) -> [Effect] {
        guard trackpadTouch == nil, let action = nearestAction(x: x, y: y) else { return [] }
        var effects = commitPending()
        var touch = Touch(id: id, role: .character, action: action, startX: x, startY: y, x: x, y: y, field: field)
        switch action {
        case .character:
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
        case .nextKeyboard:
            // The globe is a UIKit button with its own touches; a touch that lands near it is ignored.
            return effects
        }
        touches.append(touch)
        return effects
    }

    mutating func moved(_ id: TouchID, x: Double, y: Double) -> [Effect] {
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
        case .character, .slide, .layer:
            let action = nearestAction(x: x, y: y)
            guard action != touch.action else { break }
            touches[index].action = action
            if touch.role == .layer, action?.isCharacter == true { touches[index].role = .slide }
        case .delete, .returnKey, .shift:
            break
        }
        return []
    }

    mutating func ended(_ id: TouchID, x: Double, y: Double) -> [Effect] {
        if id == trackpadTouch {
            trackpadTouch = nil
            return [.endTrackpad(cancelled: false)]
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

    mutating func cancelled(_ id: TouchID) -> [Effect] {
        if id == trackpadTouch {
            trackpadTouch = nil
            return [.endTrackpad(cancelled: true)]
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

    /// The keys were rebuilt (a layer or shift change, or a new size). Held fingers follow the keys
    /// under them; a finger whose function key is gone is dropped.
    mutating func keysChanged(_ keys: [PlacedKey], layer: KeyboardLayer) -> [Effect] {
        self.keys = keys
        self.layer = layer
        var effects: [Effect] = []
        var kept: [Touch] = []
        for var touch in touches {
            if touch.committed {
                kept.append(touch)
                continue
            }
            switch touch.role {
            case .character, .slide, .layer:
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

    /// Another field became current (`field`): fingers that touched down in a different identified field
    /// end without typing; those that touched down in this one, or before any identity (they bind to
    /// the field identified next), go on (ARCHITECTURE.md, "Typing correctness is paramount").
    mutating func cancelTouches(boundElsewhereThan field: UUID?) -> [Effect] {
        guard let field else { return [] }
        var effects: [Effect] = []
        if trackpadTouch != nil, let bound = trackpadField, bound != field {
            trackpadTouch = nil
            effects.append(.endTrackpad(cancelled: true))
        }
        var kept: [Touch] = []
        for touch in touches {
            if !touch.committed, let bound = touch.field, bound != field {
                effects += release(touch)
            } else {
                kept.append(touch)
            }
        }
        touches = kept
        return effects
    }

    /// Ends every touch, for example when the keyboard disappears.
    mutating func cancelAll() -> [Effect] {
        var effects: [Effect] = []
        if trackpadTouch != nil {
            trackpadTouch = nil
            effects.append(.endTrackpad(cancelled: true))
        }
        for touch in touches { effects += release(touch) }
        touches = []
        return effects
    }

    // MARK: Helpers

    private func nearestAction(x: Double, y: Double) -> KeyAction? {
        KeyboardLayout.nearestKey(toX: x, y: y, in: keys).map { keys[$0].action }
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
        }
        return effects
    }

    private mutating func beginTrackpad(_ index: Int) -> [Effect] {
        let touch = touches.remove(at: index)
        trackpadTouch = touch.id
        trackpadField = touch.field
        return [.cancelHoldTimer(touch.id), .beginTrackpad]
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
