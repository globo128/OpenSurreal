import CoreBluetooth

/// The high-level Bluetooth availability of the host. Read it live from
/// ``SurrealControllerSession/bluetoothState`` — scanning and connecting only work
/// once it's ``poweredOn``.
public enum SurrealBluetoothState: Sendable, Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    init(_ state: CBManagerState) {
        switch state {
        case .unknown: self = .unknown
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        @unknown default: self = .unknown
        }
    }
}
