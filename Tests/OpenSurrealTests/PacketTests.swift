import XCTest
import simd
@testable import OpenSurreal

final class PacketTests: XCTestCase {

    // MARK: Helpers

    private func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private func floatBytes(_ value: Float) -> [UInt8] {
        littleEndianBytes(value.bitPattern)
    }

    // MARK: Vibration encoding

    func testVibrationEncodingMatchesReferenceProtocol() {
        // Mirrors the Python reference: struct.pack('<BHHHHI', 0x18, 0x000a, seq, amp, freq, dur)
        let data = SurrealProtocol.encodeVibration(
            sequence: 0,
            amplitude: 5000,   // 0x1388
            frequency: 100,    // 0x0064
            durationMs: 200    // 0x000000C8
        )
        let expected: [UInt8] = [
            0x18,                   // fixed opcode
            0x0a, 0x00,             // fixed 0x000a
            0x00, 0x00,             // sequence
            0x88, 0x13,             // amplitude
            0x64, 0x00,             // frequency
            0xc8, 0x00, 0x00, 0x00  // duration
        ]
        XCTAssertEqual([UInt8](data), expected)
        XCTAssertEqual(data.count, 13)
    }

    func testVibrationSequenceIsEncodedLittleEndian() {
        let data = SurrealProtocol.encodeVibration(sequence: 0x1234, amplitude: 0, frequency: 20, durationMs: 30)
        XCTAssertEqual([UInt8](data)[3], 0x34)
        XCTAssertEqual([UInt8](data)[4], 0x12)
    }

    // MARK: Button parsing

    func testButtonParsing() throws {
        var bytes = littleEndianBytes(UInt64(1))  // timestamp
        bytes.append(0x05)  // flags: primary (0x01) + menu (0x04)
        bytes.append(64)    // trigger → 64/127
        bytes.append(127)   // grip → 1.0 (full scale)
        bytes.append(128)   // joystick x → 0 (centred)
        bytes.append(192)   // joystick y → (192-128)/127

        let state = try ButtonUpdate(packet: Data(bytes), handedness: .right)
        XCTAssertEqual(state.handedness, .right)
        XCTAssertEqual(state.timestamp, 1)
        XCTAssertTrue(state.primaryButton)
        XCTAssertFalse(state.secondaryButton)
        XCTAssertTrue(state.menuButton)
        XCTAssertFalse(state.joystickClick)
        XCTAssertEqual(state.trigger, 64.0 / 127.0, accuracy: 1e-6)
        XCTAssertEqual(state.grip, 1.0, accuracy: 1e-6)
        XCTAssertEqual(state.joystick.x, 0.0, accuracy: 1e-6)
        XCTAssertEqual(state.joystick.y, 64.0 / 127.0, accuracy: 1e-6)
    }

    func testButtonAnalogNormalizationClamps() throws {
        var bytes = littleEndianBytes(UInt64(0))
        bytes.append(0x00)  // flags
        bytes.append(255)   // trigger → clamps to 1.0 (raw exceeds full-scale)
        bytes.append(255)   // grip → clamps to 1.0
        bytes.append(0)     // joystick x → (0-128)/127 clamps to -1.0
        bytes.append(255)   // joystick y → (255-128)/127 = 1.0

        let state = try ButtonUpdate(packet: Data(bytes), handedness: .left)
        XCTAssertEqual(state.trigger, 1.0, accuracy: 1e-6)
        XCTAssertEqual(state.grip, 1.0, accuracy: 1e-6)
        XCTAssertEqual(state.joystick.x, -1.0, accuracy: 1e-6)
        XCTAssertEqual(state.joystick.y, 1.0, accuracy: 1e-6)
    }

    func testButtonParsingAllFlags() throws {
        var bytes = littleEndianBytes(UInt64(0))
        bytes.append(0x0F)  // all four flag bits set
        bytes.append(contentsOf: [0, 0, 0, 0])

        let state = try ButtonUpdate(packet: Data(bytes), handedness: .left)
        XCTAssertTrue(state.primaryButton)
        XCTAssertTrue(state.secondaryButton)
        XCTAssertTrue(state.menuButton)
        XCTAssertTrue(state.joystickClick)
    }

    func testButtonRejectsShortPacket() {
        XCTAssertThrowsError(try ButtonUpdate(packet: Data([0x00, 0x01, 0x02]), handedness: .left))
    }

    // MARK: Pose parsing

    func testPoseParsingConvertsToRightHanded() throws {
        var bytes = littleEndianBytes(UInt64(42))  // timestamp
        let floats: [Float] = [
            1, 2, 3,                // position
            0.1, 0.2, 0.3, 0.4,     // quaternion (x, y, z, w)
            0.9,                    // confidence
            10, 11, 12,             // linear velocity
            20, 21, 22,             // angular velocity
            30, 31, 32              // acceleration
        ]
        for value in floats { bytes.append(contentsOf: floatBytes(value)) }

        XCTAssertEqual(bytes.count, SurrealProtocol.posePacketSize)

        let pose = try ControllerPose(packet: Data(bytes), handedness: .left)
        XCTAssertEqual(pose.handedness, .left)
        XCTAssertEqual(pose.timestamp, 42)
        XCTAssertEqual(pose.confidence, 0.9, accuracy: 1e-6)

        // Right-handed conversion: polar vectors flip Z; the quaternion and the
        // axial angular-velocity vector negate X and Y.
        XCTAssertEqual(pose.position, SIMD3<Float>(1, 2, -3))
        XCTAssertEqual(pose.quaternion, SIMD4<Float>(-0.1, -0.2, 0.3, 0.4))
        XCTAssertEqual(pose.linearVelocity, SIMD3<Float>(10, 11, -12))
        XCTAssertEqual(pose.angularVelocity, SIMD3<Float>(-20, -21, 22))
        XCTAssertEqual(pose.acceleration, SIMD3<Float>(30, 31, -32))

        // The convenience accessor reflects the converted quaternion.
        XCTAssertEqual(pose.orientation.real, 0.4, accuracy: 1e-6)
        XCTAssertEqual(pose.orientation.imag, SIMD3<Float>(-0.1, -0.2, 0.3))
    }

    func testIdentityQuaternionSurvivesConversion() throws {
        var bytes = littleEndianBytes(UInt64(0))
        let floats: [Float] = [0, 0, 0,  0, 0, 0, 1,  1,  0, 0, 0,  0, 0, 0,  0, 0, 0]
        for value in floats { bytes.append(contentsOf: floatBytes(value)) }

        let pose = try ControllerPose(packet: Data(bytes), handedness: .right)
        XCTAssertEqual(pose.quaternion, SIMD4<Float>(0, 0, 0, 1))
        XCTAssertEqual(pose.orientation.real, 1, accuracy: 1e-6)
    }

    func testPoseRejectsShortPacket() {
        XCTAssertThrowsError(try ControllerPose(packet: Data([0x00, 0x01]), handedness: .left))
    }

    // MARK: Handedness

    func testHandednessParsing() {
        XCTAssertEqual(Handedness(name: "Surreal Touch L D5A8"), .left)
        XCTAssertEqual(Handedness(name: "Surreal Touch R C07E"), .right)
        XCTAssertEqual(Handedness(name: "Surreal Touch L"), .left)
        XCTAssertEqual(Handedness(name: "Surreal Touch R"), .right)
        XCTAssertEqual(Handedness(name: "Surreal Controller"), .unspecified)
    }

    // MARK: Duration helper

    func testDurationInMilliseconds() {
        XCTAssertEqual(Duration.milliseconds(200).inMilliseconds, 200)
        XCTAssertEqual(Duration.seconds(1).inMilliseconds, 1000)
        XCTAssertEqual(Duration.milliseconds(-5).inMilliseconds, 0)
        XCTAssertEqual((Duration.seconds(2) + .milliseconds(500)).inMilliseconds, 2500)
    }
}
