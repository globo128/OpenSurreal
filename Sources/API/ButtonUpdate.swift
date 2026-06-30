import Foundation
import simd

/// A snapshot of a controller's buttons, triggers, and joystick, tagged with the
/// hand it came from. Delivered on ``SurrealControllerSession/buttonUpdates``.
public struct ButtonUpdate: Sendable, Equatable {
    /// Which hand produced this snapshot.
    public let handedness: Handedness
    /// Device timestamp in firmware-defined units.
    public let timestamp: UInt64
    /// The X (left controller) / A (right controller) face button.
    public let primaryButton: Bool
    /// The Y (left controller) / B (right controller) face button.
    public let secondaryButton: Bool
    /// The menu (left) / capture (right) button.
    public let menuButton: Bool
    /// Whether the joystick is pressed in (clicked).
    public let joystickClick: Bool
    /// Analog trigger, normalized `0` (released) … `1` (fully squeezed).
    public let trigger: Float
    /// Analog grip, normalized `0` (released) … `1` (fully squeezed).
    public let grip: Float
    /// Joystick position, each axis normalized `-1 … 1` with `0` at rest. The centre
    /// and axis orientation are device assumptions (see ``SurrealProtocol``); flip an
    /// axis on your side if a stick reads inverted for your hardware.
    public let joystick: SIMD2<Float>
}

extension ButtonUpdate {
    /// Parses a 13-byte little-endian button packet (`<QBBBBB`) and tags it with
    /// `handedness`.
    init(packet: Data, handedness: Handedness) throws {
        guard packet.count >= SurrealProtocol.buttonPacketSize else {
            throw SurrealError.malformedPacket
        }
        var reader = ByteReader(packet)
        let timestamp = try reader.readUInt64()
        let flags = try reader.readUInt8()
        let trigger = try reader.readUInt8()
        let grip = try reader.readUInt8()
        let x = try reader.readUInt8()
        let y = try reader.readUInt8()

        self.handedness = handedness
        self.timestamp = timestamp
        self.primaryButton = flags & 0x01 != 0
        self.secondaryButton = flags & 0x02 != 0
        self.menuButton = flags & 0x04 != 0
        self.joystickClick = flags & 0x08 != 0
        self.trigger = Self.normalizeAnalog(trigger)
        self.grip = Self.normalizeAnalog(grip)
        self.joystick = SIMD2(Self.normalizeAxis(x), Self.normalizeAxis(y))
    }

    /// Maps a raw trigger/grip byte to `0...1` against the device full-scale.
    private static func normalizeAnalog(_ raw: UInt8) -> Float {
        min(Float(raw) / SurrealProtocol.analogFullScale, 1)
    }

    /// Maps a raw joystick axis byte to `-1...1` about the device centre.
    private static func normalizeAxis(_ raw: UInt8) -> Float {
        let value = (Float(raw) - SurrealProtocol.joystickCenter) / SurrealProtocol.analogFullScale
        return max(-1, min(1, value))
    }
}
