import Foundation
import simd

/// A single 6DOF pose sample in a controller's own tracking frame, tagged with the
/// hand it came from. Delivered on ``SurrealControllerSession/poseUpdates``.
///
/// Vectors are expressed in a **right-handed** frame (X right, Y up, −Z forward),
/// matching ARKit / RealityKit. The device's native frame is left-handed (mirrored
/// along its forward Z axis); OpenSurreal converts every sample to right-handed at
/// parse time so poses drop straight into Apple's 3D frameworks.
///
/// The origin is the controller's own tracking origin (established at power-on), so
/// positions are deltas from that origin rather than a shared world coordinate. For
/// absolute placement in the headset's world space, use
/// ``SurrealControllerSession/worldPoseUpdates`` instead. Units are metres.
public struct ControllerPose: Sendable, Equatable {
    /// Which hand produced this pose.
    public let handedness: Handedness
    /// Device timestamp in firmware-defined units (nanoseconds on current firmware:
    /// consecutive packets are ~9.5e6 ticks apart at ~105 Hz).
    public let timestamp: UInt64
    /// Position `(x, y, z)`, right-handed.
    public let position: SIMD3<Float>
    /// Tracking confidence reported by the device (scale is device-defined).
    public let confidence: Float
    /// Linear velocity `(x, y, z)`.
    public let linearVelocity: SIMD3<Float>
    /// Angular velocity `(x, y, z)`.
    public let angularVelocity: SIMD3<Float>
    /// Linear acceleration `(x, y, z)`.
    public let acceleration: SIMD3<Float>

    /// Orientation quaternion `(x, y, z, w)`, right-handed.
    let quaternion: SIMD4<Float>

    /// The orientation as a `simd_quatf` for convenient math/rendering.
    public var orientation: simd_quatf {
        simd_quatf(ix: quaternion.x, iy: quaternion.y, iz: quaternion.z, r: quaternion.w)
    }
}

extension ControllerPose {
    /// The controller-frame pose as a 4×4 rigid transform (rotation then
    /// translation), for composing with a calibration transform.
    var matrix: simd_float4x4 {
        var m = simd_float4x4(orientation)
        m.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        return m
    }

    /// Parses a 76-byte little-endian pose packet (`<Q` + 17 × `f`), tags it with
    /// `handedness`, and converts it from the device's left-handed frame to a
    /// right-handed one.
    ///
    /// The device frame is mirrored along its forward (Z) axis. Converting to
    /// right-handed flips Z on **polar** vectors (position, linear velocity,
    /// acceleration) and negates X and Y on **axial** quantities (the orientation
    /// quaternion's imaginary part and the angular-velocity pseudovector).
    init(packet: Data, handedness: Handedness) throws {
        guard packet.count >= SurrealProtocol.posePacketSize else {
            throw SurrealError.malformedPacket
        }
        var reader = ByteReader(packet)
        let timestamp = try reader.readUInt64()

        let rawPosition = SIMD3(try reader.readFloat(), try reader.readFloat(), try reader.readFloat())
        let rawQuaternion = SIMD4(
            try reader.readFloat(), try reader.readFloat(),
            try reader.readFloat(), try reader.readFloat()
        )
        let confidence = try reader.readFloat()
        let rawLinearVelocity = SIMD3(try reader.readFloat(), try reader.readFloat(), try reader.readFloat())
        let rawAngularVelocity = SIMD3(try reader.readFloat(), try reader.readFloat(), try reader.readFloat())
        let rawAcceleration = SIMD3(try reader.readFloat(), try reader.readFloat(), try reader.readFloat())

        self.handedness = handedness
        self.timestamp = timestamp
        self.position = SIMD3(rawPosition.x, rawPosition.y, -rawPosition.z)
        self.quaternion = SIMD4(-rawQuaternion.x, -rawQuaternion.y, rawQuaternion.z, rawQuaternion.w)
        self.confidence = confidence
        self.linearVelocity = SIMD3(rawLinearVelocity.x, rawLinearVelocity.y, -rawLinearVelocity.z)
        self.angularVelocity = SIMD3(-rawAngularVelocity.x, -rawAngularVelocity.y, rawAngularVelocity.z)
        self.acceleration = SIMD3(rawAcceleration.x, rawAcceleration.y, -rawAcceleration.z)
    }
}
