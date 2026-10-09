import Foundation

/// The edit generation: a token that changes whenever the document may have changed in a way the
/// current owner of an operation (an undo or a trackpad gesture) did not cause. Owners remember the
/// generation they started at and stop as soon as it differs. Pure.
///
/// Host callbacks (`textDidChange`, `selectionDidChange`) carry no cause. Measured in the iOS 26.4
/// simulator: our own `insertText` and `deleteBackward` produce none, `adjustTextPosition`
/// produces `textWillChange`/`textDidChange` about 10 ms later, and a caret move by the host app
/// arrives as `textDidChange`. So a callback counts as ours only if it arrives within
/// `ownCallbackWindow` of our own operation and its context fits that operation; anything else is
/// an outside change.
struct EditTracker: Equatable, Sendable {
    static let ownCallbackWindow: TimeInterval = 0.5

    private(set) var generation = 0
    private(set) var lastOwnOperationAt: TimeInterval?

    /// An edit the current owner did not make: typing, delete, an insertion, a focus change, hiding.
    mutating func change() {
        generation &+= 1
    }

    /// The owner itself changed the document (an undo step or a trackpad adjustment).
    mutating func ownOperation(at time: TimeInterval) {
        lastOwnOperationAt = max(time, lastOwnOperationAt ?? time)
    }

    /// A host callback. Returns true when it is an outside change, which advances the generation.
    @discardableResult
    mutating func hostCallback(at time: TimeInterval, fitsOwnOperation: Bool) -> Bool {
        if fitsOwnOperation, let ownAt = lastOwnOperationAt, time >= ownAt, time - ownAt <= Self.ownCallbackWindow {
            return false
        }
        change()
        return true
    }
}
