/// A snapshot of how many controllers — and which hands — are currently connected
/// to a ``SurrealControllerSession``.
///
/// Read it live from ``SurrealControllerSession/connectionState``, or observe every
/// change as ``SurrealControllerEvent/connection(_:)`` on
/// ``SurrealControllerSession/stateUpdates``.
public enum SurrealConnectionState: Sendable, Equatable {
    /// No controllers connected and nothing connecting.
    case disconnected
    /// A connection attempt is in flight with no controller connected yet.
    case connecting
    /// Exactly one controller connected: the left hand.
    case leftConnected
    /// Exactly one controller connected: the right hand.
    case rightConnected
    /// Both controllers connected.
    case bothConnected
}
