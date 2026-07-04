import Foundation

/// A controller's battery level, tagged with the hand it came from. Delivered on
/// ``SurrealControllerSession/batteryUpdates`` and also mirrored as an observable
/// value on each connected controller for the bundled management UI.
///
/// The level comes from the standard Bluetooth SIG Battery Service, which reports a
/// percentage only — there is no charging/plugged-in flag in that service.
public struct BatteryUpdate: Sendable, Equatable {
    /// Which hand produced this reading.
    public let handedness: Handedness
    /// Battery charge as a percentage, `0…100`.
    public let level: UInt8
}

extension BatteryUpdate {
    /// Parses a Battery Level packet — a single `uint8` percentage — and tags it with
    /// `handedness`.
    init(packet: Data, handedness: Handedness) throws {
        guard packet.count >= SurrealProtocol.batteryPacketSize else {
            throw SurrealError.malformedPacket
        }
        var reader = ByteReader(packet)
        self.level = try reader.readUInt8()
        self.handedness = handedness
    }
}
