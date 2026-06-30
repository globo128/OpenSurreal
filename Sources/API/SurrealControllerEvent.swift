/// An event emitted on ``SurrealControllerSession/stateUpdates``.
///
/// ```swift
/// for await event in session.stateUpdates {
///     switch event {
///     case .connection(let state): updateUI(state)
///     case .paused(let hand):  // controller set down — stopped following the hand
///     case .resumed(let hand): // picked up again
///     }
/// }
/// ```
public enum SurrealControllerEvent: Sendable, Equatable {
    /// The session's overall connection state changed. The current value is also
    /// available any time from ``SurrealControllerSession/connectionState``.
    case connection(SurrealConnectionState)
    /// A connected controller was set down and is no longer following the user's
    /// hand, so its world poses pause until it's picked up.
    case paused(Handedness)
    /// A previously set-down controller was picked up again and resumes tracking.
    case resumed(Handedness)
}
