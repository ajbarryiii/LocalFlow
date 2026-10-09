import Foundation

/// Time-based reasons for the host to stop an in-progress request on its own.
enum HostWatchdog {
    /// Why the host must stop `current` now, if it must:
    /// - `.startupTimeout` (report failed): admitted but no audio within `startupTimeout`.
    /// - `.keyboardDismissed` (cancel): starting or recording while the app is in the background and
    ///   no keyboard has been visible for `keyboardPresenceTimeout`.
    ///
    /// `lastForegroundAt` is when the app was last in the foreground during this run. It counts like a
    /// presence record, so the moment after the swipe back from a long bounce, before the keyboard
    /// reappears and writes presence, is not a dismissal.
    static func stopReason(current: DictationStatus?, presence: StoreRead<KeyboardPresence>, isForeground: Bool,
                           lastForegroundAt: Date?, now: Date) -> HostErrorCode? {
        guard let current, current.phase == .starting || current.phase == .recording else { return nil }
        if current.phase == .starting,
           !DictationProtocol.isFresh(current.startedAt, ttl: DictationProtocol.startupTimeout, now: now) {
            return .startupTimeout
        }
        guard !isForeground else { return nil }
        let timeout = DictationProtocol.keyboardPresenceTimeout
        let seen = [presence.value?.seenAt, lastForegroundAt].compactMap { $0 }
        return seen.contains { DictationProtocol.isFresh($0, ttl: timeout, now: now) } ? nil : .keyboardDismissed
    }
}
