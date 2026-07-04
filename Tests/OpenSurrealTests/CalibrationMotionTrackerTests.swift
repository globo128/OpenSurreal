import XCTest
import simd
@testable import OpenSurreal

final class CalibrationMotionTrackerTests: XCTestCase {

    private let frame = 1.0 / 90.0

    private func transform(_ orientation: simd_quatf, _ position: SIMD3<Float>) -> simd_float4x4 {
        var matrix = simd_float4x4(orientation)
        matrix.columns.3 = SIMD4<Float>(position, 1)
        return matrix
    }

    /// A calibration translating at constant velocity should converge to that
    /// velocity (EWMA tau is 0.1 s; a second of updates is fully converged).
    func testRecoversConstantTranslationVelocity() {
        var tracker = CalibrationMotionTracker()
        let velocity = SIMD3<Float>(1.0, -0.5, 0.25)
        for i in 0...90 {
            let t = Double(i) * frame
            tracker.update(transform(simd_quatf(), velocity * Float(t)), at: t)
        }
        XCTAssertLessThan(simd_length(tracker.linearVelocity - velocity), 0.02)
        XCTAssertLessThan(simd_length(tracker.angularVelocity), 0.01)
    }

    /// A calibration rotating at a constant rate should converge to that world-frame
    /// angular velocity.
    func testRecoversConstantRotationRate() {
        var tracker = CalibrationMotionTracker()
        let rate: Float = 1.2 // rad/s about world Y
        for i in 0...90 {
            let t = Double(i) * frame
            let orientation = simd_quatf(angle: rate * Float(t), axis: SIMD3(0, 1, 0))
            tracker.update(transform(orientation, .zero), at: t)
        }
        XCTAssertLessThan(simd_length(tracker.angularVelocity - SIMD3(0, rate, 0)), 0.02)
        XCTAssertLessThan(simd_length(tracker.linearVelocity), 0.01)
    }

    /// A snap (calibration jump far beyond any physical correction rate) is a
    /// correction, not motion — velocities must reset to zero, not spike.
    func testSnapResetsInsteadOfSpiking() {
        var tracker = CalibrationMotionTracker()
        var t = 0.0
        for _ in 0..<20 {
            tracker.update(transform(simd_quatf(), .zero), at: t)
            t += frame
        }
        // 0.5 m jump in one 90 Hz frame = 45 m/s — way past the discontinuity bound.
        tracker.update(transform(simd_quatf(), SIMD3(0.5, 0, 0)), at: t)
        XCTAssertEqual(simd_length(tracker.linearVelocity), 0)
        XCTAssertEqual(simd_length(tracker.angularVelocity), 0)
    }

    /// Updates separated by more than the max gap can't be differenced — velocities
    /// reset rather than treating the whole gap's displacement as one frame of motion.
    func testGapResetsVelocity() {
        var tracker = CalibrationMotionTracker()
        let velocity = SIMD3<Float>(1, 0, 0)
        for i in 0...45 {
            let t = Double(i) * frame
            tracker.update(transform(simd_quatf(), velocity * Float(t)), at: t)
        }
        XCTAssertGreaterThan(simd_length(tracker.linearVelocity), 0.5)
        tracker.update(transform(simd_quatf(), SIMD3(2, 0, 0)), at: 10.0)
        XCTAssertEqual(simd_length(tracker.linearVelocity), 0)
    }

    func testResetClearsState() {
        var tracker = CalibrationMotionTracker()
        for i in 0...30 {
            let t = Double(i) * frame
            tracker.update(transform(simd_quatf(), SIMD3(Float(t), 0, 0)), at: t)
        }
        tracker.reset()
        XCTAssertEqual(simd_length(tracker.linearVelocity), 0)
        // First update after a reset has nothing to difference against.
        tracker.update(transform(simd_quatf(), SIMD3(5, 5, 5)), at: 100.0)
        XCTAssertEqual(simd_length(tracker.linearVelocity), 0)
    }

    /// WorldPose prediction: constant velocity and angular rate extrapolate the
    /// transform forward from its sample time.
    func testWorldPosePredictedTransform() {
        let pose = WorldPose(
            handedness: .right,
            transform: matrix_identity_float4x4,
            timestamp: 0,
            sampleTime: 10.0,
            confidence: 1.0,
            linearVelocity: SIMD3(1, 0, 0),
            angularVelocity: SIMD3(0, .pi, 0), // half-turn per second about Y
            acceleration: .zero
        )
        let predicted = pose.predictedTransform(at: 10.05)
        XCTAssertEqual(predicted.columns.3.x, 0.05, accuracy: 1e-5)
        let orientation = simd_quatf(simd_float3x3(
            SIMD3(predicted.columns.0.x, predicted.columns.0.y, predicted.columns.0.z),
            SIMD3(predicted.columns.1.x, predicted.columns.1.y, predicted.columns.1.z),
            SIMD3(predicted.columns.2.x, predicted.columns.2.y, predicted.columns.2.z)
        ))
        let expected = simd_quatf(angle: .pi * 0.05, axis: SIMD3(0, 1, 0))
        // |q·q̂| = 1 iff same rotation (sign-insensitive).
        XCTAssertEqual(abs(simd_dot(orientation.vector, expected.vector)), 1, accuracy: 1e-4)

        // Clamped: a stale pose stops moving instead of flying off.
        let farFuture = pose.predictedTransform(at: 20.0, maxPrediction: 0.1)
        XCTAssertEqual(farFuture.columns.3.x, 0.1, accuracy: 1e-5)
    }
}
