import Foundation
import simd

/// Tracks the velocity of the calibration frame itself by differencing consecutive
/// calibration transforms.
///
/// While the wrist is authoritative the calibration is re-registered onto the moving
/// wrist every hand update, so the calibration's own motion carries the part of the
/// controller's world motion that the device's reported velocities can't see (the
/// device only knows its motion in its own tracking frame). Completing the world
/// velocity needs both parts:
///
///     worldLinearVelocity  = R_cal·v_device + v_cal + ω_cal × (p_world − t_cal)
///     worldAngularVelocity = R_cal·ω_device + ω_cal
///
/// This tracker supplies `v_cal` (translation rate) and `ω_cal` (world-frame angular
/// rate) — the caller composes the cross-term, which depends on the pose being
/// transformed. Velocities are lightly smoothed; a discontinuity (calibration snap,
/// update gap) resets them to zero rather than emitting a spike, since a snap is a
/// correction, not motion.
struct CalibrationMotionTracker {
    /// Updates further apart than this (dropped hand anchors, authority regained)
    /// can't be differenced.
    static let maxGap: TimeInterval = 0.2
    /// EWMA time constant. The calibration is already smoothed upstream; this only
    /// knocks down frame-rate differencing noise.
    static let smoothingTau: TimeInterval = 0.1
    /// A frame-to-frame calibration velocity beyond these is a snap, not motion —
    /// the smoother's correction rate is bounded well below them, and even the
    /// reacquisition window (calibration pinned to the raw wrist) can't exceed how
    /// fast a hand physically moves.
    static let linearDiscontinuity: Float = 4.0   // m/s
    static let angularDiscontinuity: Float = 10.0 // rad/s

    private(set) var linearVelocity = SIMD3<Float>.zero
    private(set) var angularVelocity = SIMD3<Float>.zero

    private var last: (transform: simd_float4x4, time: TimeInterval)?

    mutating func update(_ transform: simd_float4x4, at time: TimeInterval) {
        defer { last = (transform, time) }
        guard let last, time > last.time, time - last.time <= Self.maxGap else {
            linearVelocity = .zero
            angularVelocity = .zero
            return
        }
        let dt = Float(time - last.time)

        let translationRate = SIMD3(
            transform.columns.3.x - last.transform.columns.3.x,
            transform.columns.3.y - last.transform.columns.3.y,
            transform.columns.3.z - last.transform.columns.3.z
        ) / dt

        // World-frame rotation delta, shortest path: q_now = Δq · q_last.
        var delta = simd_quatf(rotation(of: transform)) * simd_quatf(rotation(of: last.transform)).inverse
        if delta.real < 0 {
            delta = simd_quatf(vector: -delta.vector)
        }
        let imaginaryLength = simd_length(delta.imag)
        var rotationRate = SIMD3<Float>.zero
        if imaginaryLength > 1e-6 {
            let angle = 2 * atan2(imaginaryLength, delta.real)
            rotationRate = (delta.imag / imaginaryLength) * (angle / dt)
        }

        guard simd_length(translationRate) < Self.linearDiscontinuity,
              simd_length(rotationRate) < Self.angularDiscontinuity else {
            linearVelocity = .zero
            angularVelocity = .zero
            return
        }

        let alpha = Float(1 - exp(-Double(dt) / Self.smoothingTau))
        linearVelocity += (translationRate - linearVelocity) * alpha
        angularVelocity += (rotationRate - angularVelocity) * alpha
    }

    /// Forgets all motion state — call when the calibration freezes (authority lost)
    /// so stale velocity can't leak into the next authoritative stretch.
    mutating func reset() {
        last = nil
        linearVelocity = .zero
        angularVelocity = .zero
    }

    private func rotation(of transform: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
    }
}
