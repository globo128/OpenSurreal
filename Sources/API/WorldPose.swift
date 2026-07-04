import Foundation
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
    /// Device timestamp of the underlying controller sample, in firmware ticks
    /// (nanoseconds on current firmware). Prefer ``sampleTime`` for host-side timing.
    public let timestamp: UInt64
    /// Estimated host-clock time the sample was measured, in the
    /// `CACurrentMediaTime()` timebase (the same clock as ARKit anchor timestamps and
    /// CADisplayLink). Derived from the firmware timestamp via a continuously
    /// estimated clock offset, so it reflects when the controller *measured* the
    /// pose, not when Bluetooth happened to deliver it — use it for prediction and
    /// latency math.
    public let sampleTime: TimeInterval

    /// How much to trust this pose, `0...1`.
    ///
    /// While the headset's hand tracking has a solid lock on the wrist, the wrist is
    /// authoritative for ``transform`` and this is `1.0`. When the wrist isn't tracked
    /// the controller coasts on its own tracking (calibrated to the last time the
    /// wrist was visible) and this reports the controller's own device confidence —
    /// the same value as ``ControllerPose/confidence``.
    public let confidence: Float

    /// Linear velocity `(x, y, z)` in world axes — the **complete** world-space
    /// velocity, useful for, e.g., throw-release velocity.
    ///
    /// This composes the controller's own reported velocity (rotated into world
    /// axes) with the motion of the calibration frame itself: while the wrist is
    /// authoritative the frame is re-registered onto the moving wrist each update,
    /// and that registration motion is included here. While the calibration is
    /// frozen (coasting) the frame contributes nothing.
    public let linearVelocity: SIMD3<Float>
    /// Angular velocity `(x, y, z)` in world axes, rad/s. Composed the same way as
    /// ``linearVelocity``.
    public let angularVelocity: SIMD3<Float>
    /// Linear acceleration `(x, y, z)` in world axes. Unlike the velocities, this is
    /// the controller's own reported acceleration only (rotated into world axes) —
    /// calibration-frame acceleration is not observable.
    public let acceleration: SIMD3<Float>

    init(
        handedness: Handedness,
        transform: simd_float4x4,
        timestamp: UInt64,
        sampleTime: TimeInterval,
        confidence: Float,
        linearVelocity: SIMD3<Float>,
        angularVelocity: SIMD3<Float>,
        acceleration: SIMD3<Float>
    ) {
        self.handedness = handedness
        self.transform = transform
        self.timestamp = timestamp
        self.sampleTime = sampleTime
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

    /// The pose extrapolated to `hostTime` (in the ``sampleTime`` timebase, i.e.
    /// `CACurrentMediaTime()`), using the pose's own velocities — position by
    /// constant velocity, orientation by constant angular rate.
    ///
    /// BLE poses arrive at ~100 Hz while rendering runs faster; extrapolating each
    /// sample to the frame's display time hides most of the transport latency. The
    /// extrapolation horizon is clamped to `0...maxPrediction` seconds, so a stale
    /// pose stops moving instead of flying off.
    public func predictedTransform(
        at hostTime: TimeInterval,
        maxPrediction: TimeInterval = 0.1
    ) -> simd_float4x4 {
        let dt = Float(min(max(hostTime - sampleTime, 0), maxPrediction))
        var orientation = self.orientation
        let angularSpeed = simd_length(angularVelocity)
        if angularSpeed > 0 {
            // World-frame pre-multiply: the angular velocity is expressed in world axes.
            orientation = simd_normalize(
                simd_quatf(angle: angularSpeed * dt, axis: angularVelocity / angularSpeed) * orientation
            )
        }
        var predicted = simd_float4x4(orientation)
        let position = self.position + linearVelocity * dt
        predicted.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        return predicted
    }
}
