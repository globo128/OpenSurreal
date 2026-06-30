import Foundation

/// A controller found while scanning, before a connection is established. Read the
/// live list from ``SurrealControllerSession/discoveredControllers`` and pass one to
/// ``SurrealControllerSession/connect(_:)``.
public struct DiscoveredController: Sendable, Identifiable, Equatable {
    /// Stable per-device identifier assigned by CoreBluetooth on this host.
    public let id: UUID
    /// Advertised device name, or a default if none is advertised.
    public let name: String
    /// Latest advertisement signal strength in dBm.
    public let rssi: Int
}
