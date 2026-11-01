import ActivityKit

/// The session's Live Activity (ARCHITECTURE.md, "Live Activity"), compiled into the app, which requests it, and the
/// extension, which draws it. It has no fixed attributes: everything it shows is the `SessionActivityState`.
struct SessionActivityAttributes: ActivityAttributes {
    typealias ContentState = SessionActivityState
}
