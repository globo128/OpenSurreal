/// Errors surfaced internally by the OpenSurreal BLE layer. Failures reach the app
/// as human-readable text on ``SurrealControllerSession`` UI state, not as thrown
/// errors, so this type is internal.
enum SurrealError: Error, Sendable, Equatable {
    /// The requested controller is not (or no longer) known to the central.
    case peripheralNotFound
    /// The connection attempt failed or dropped during setup.
    case connectionFailed(String?)
    /// The expected Surreal GATT service was not found on the device.
    case serviceNotFound
    /// One or more required characteristics were not found on the device.
    case characteristicsNotFound
    /// An operation was attempted on a controller that is not connected.
    case notConnected
    /// The controller disconnected.
    case disconnected(String?)
    /// A received packet did not match the expected layout.
    case malformedPacket
    /// A vibration parameter was out of range.
    case invalidParameter(String)
}
