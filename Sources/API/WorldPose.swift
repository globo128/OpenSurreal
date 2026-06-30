import simd

/// A controller pose in the **headset's world coordinate space**, tagged with the
/// hand it came from.
///
/// `transform` is `worldFromController`: drop it straight into a RealityKit
/// `Entity`'s transform inside an `ImmersiveSpace` `RealityView` (that content space
/// shares the same world origin as ARKit). Delivered on
/// ``SurrealControllerSession/worldPoseUpdates`` once the controller is calibrated —
/// i.e. while spatial tracking is running.
public struct WorldPose: Sendable, Equatable {
    /// Which hand produced this pose.
    public let handedness: Handedness
    /// World-from-controller transform.
    public let transform: simd_float4x4
    /// Device timestamp of the underlying controller sample.
    public let timestamp: UInt64

    /// How much to trust this pose, `0...1`.
    ///
    /// While the headset's hand tracking has a solid lock on the wrist, the wrist is
    /// authoritative for ``transform`` and this is `1.0`. When the wrist isn't tracked
    /// the controller coasts on its own tracking (calibrated to the last time the
    /// wrist was visible) and this reports the controller's own device confidence —
    /// the same value as ``ControllerPose/confidence``.
    public let confidence: Float

    /// Linear velocity `(x, y, z)` in world axes.
    ///
    /// The controller's reported velocity rotated into world space — useful for, e.g.,
    /// throw-release velocity. It reflects only the controller's own motion; it
    /// excludes any motion of the calibration frame itself (while the wrist is
    /// authoritative the frame is re-registered onto the moving wrist each update, and
    /// that registration motion is not included here).
    public let linearVelocity: SIMD3<Float>
    /// Angular velocity `(x, y, z)` in world axes. See ``linearVelocity`` for how it's
    /// derived.
    public let angularVelocity: SIMD3<Float>
    /// Linear acceleration `(x, y, z)` in world axes. See ``linearVelocity`` for how
    /// it's derived.
    public let acceleration: SIMD3<Float>

    init(
        handedness: Handedness,
        transform: simd_float4x4,
        timestamp: UInt64,
        confidence: Float,
        linearVelocity: SIMD3<Float>,
        angularVelocity: SIMD3<Float>,
        acceleration: SIMD3<Float>
    ) {
        self.handedness = handedness
        self.transform = transform
        self.timestamp = timestamp
        self.confidence = confidence
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
        self.acceleration = acceleration
    }

    /// World-space position.
    public var position: SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    /// World-space orientation.
    public var orientation: simd_quatf {
        simd_quatf(simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        ))
    }
}
