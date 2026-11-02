import ActivityKit
import Foundation

/// ActivityKit for `SessionActivityDriver` (HostCore), which makes every decision (ARCHITECTURE.md, "Live Activity").
/// Updates carry no alert, so they never sound or wake the screen. ActivityKit's calls are asynchronous; they run one
/// after another, in the order the driver made them, and each acts on the activity as it is when its turn comes.
@MainActor
final class LiveActivityBackend: SessionActivityBackend {
    private var activity: Activity<SessionActivityAttributes>?
    private var queue: Task<Void, Never>?
    /// Calls queued and not yet finished.
    private var pending = 0

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func endLeftovers() {
        // Taken now, so an activity this run starts later is never among them.
        let leftovers = Activity<SessionActivityAttributes>.activities
        guard !leftovers.isEmpty else { return }
        enqueue {
            for leftover in leftovers { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// With nothing queued, the request is made now and its refusal reported. Behind an end still in flight (a leftover
    /// at launch, the previous session's) it waits its turn, so the ended activity no longer counts against the
    /// system's limit; a refusal then only leaves the session without an activity.
    func start(_ content: SessionActivityContent) -> Bool {
        guard pending > 0 else { return request(content) }
        enqueue { [weak self] in _ = self?.request(content) }
        return true
    }

    func update(_ content: SessionActivityContent) {
        enqueue { [weak self] in await self?.activity?.update(Self.content(content)) }
    }

    func end() {
        enqueue { [weak self] in
            guard let self, let activity = self.activity else { return }
            self.activity = nil
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func request(_ content: SessionActivityContent) -> Bool {
        do {
            activity = try Activity.request(attributes: SessionActivityAttributes(), content: Self.content(content))
            return true
        } catch {
            return false
        }
    }

    private static func content(_ content: SessionActivityContent) -> ActivityContent<SessionActivityState> {
        ActivityContent(state: content.state, staleDate: content.staleDate)
    }

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = queue
        pending += 1
        queue = Task { @MainActor in
            await previous?.value
            await work()
            self.pending -= 1
        }
    }
}
