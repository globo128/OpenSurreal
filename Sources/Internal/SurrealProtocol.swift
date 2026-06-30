import Foundation
import CoreBluetooth

/// Low-level definitions of the Surreal Touch BLE GATT protocol.
///
/// The controller exposes a single custom service (built on the Nordic UART
/// 128-bit base UUID) with three characteristics:
///
/// - **Pose** (`6e401002…`): notify, 76-byte little-endian pose packets.
/// - **Button** (`6e401003…`): notify, 13-byte little-endian button packets.
/// - **Vibration** (`6e401004…`): write, 13-byte little-endian haptic commands.
///
/// All multi-byte fields are little-endian.
enum SurrealProtocol {
    // CBUUID is effectively immutable but not marked Sendable by CoreBluetooth, so
    // these shared constants are annotated `nonisolated(unsafe)`.
    nonisolated(unsafe) static let serviceUUID = CBUUID(string: "6e401001-b5a3-f393-e0a9-e50e24dcca9e")
    nonisolated(unsafe) static let poseCharacteristicUUID = CBUUID(string: "6e401002-b5a3-f393-e0a9-e50e24dcca9e")
    nonisolated(unsafe) static let buttonCharacteristicUUID = CBUUID(string: "6e401003-b5a3-f393-e0a9-e50e24dcca9e")
    nonisolated(unsafe) static let vibrationCharacteristicUUID = CBUUID(string: "6e401004-b5a3-f393-e0a9-e50e24dcca9e")

    /// Expected size of a pose packet: `uint64` timestamp + 17 × `float32`.
    static let posePacketSize = 76
    /// Expected size of a button packet: `uint64` timestamp + 5 × `uint8`.
    static let buttonPacketSize = 13

    /// Full-scale raw value of the analog trigger and grip. Though the fields are
    /// `uint8`, the hardware reads ~0–127 at full input (verified on the trigger; the
    /// grip is assumed to match), so normalized `0...1` values divide by this and clamp.
    /// Retune if a controller revision uses the full 0–255 range.
    static let analogFullScale: Float = 127
    /// Raw value the joystick axes rest at when centred. Normalized `-1...1` axes are
    /// `(raw − center) / analogFullScale`, clamped. This and the axis orientation are
    /// assumptions — adjust if a stick rests off-centre or reads inverted.
    static let joystickCenter: Float = 128

    /// Encodes a vibration command.
    ///
    /// Wire format (`<BHHHHI`):
    /// `0x18`, `0x000a`, sequence, amplitude, frequency, durationMs.
    /// The two leading constants are fixed opcode/length values defined by the device.
    static func encodeVibration(
        sequence: UInt16,
        amplitude: UInt16,
        frequency: UInt16,
        durationMs: UInt32
    ) -> Data {
        var data = Data(capacity: 13)
        data.append(0x18)
        data.appendLittleEndian(UInt16(0x000a))
        data.appendLittleEndian(sequence)
        data.appendLittleEndian(amplitude)
        data.appendLittleEndian(frequency)
        data.appendLittleEndian(durationMs)
        return data
    }
}
