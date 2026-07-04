import XCTest
import simd
@testable import OpenSurreal

final class CalibrationSmootherTests: XCTestCase {

    private let frame = 1.0 / 90.0

    // MARK: Helpers

    private func transform(_ orientation: simd_quatf, _ position: SIMD3<Float>) -> simd_float4x4 {
        var matrix = simd_float4x4(orientation)
        matrix.columns.3 = SIMD4<Float>(position, 1)
        return matrix
    }

    private func position(of matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
    }

    /// World pose the controller would emit for the given calibration + device pose.
    private func worldPose(_ calibration: simd_float4x4, _ devicePose: simd_float4x4) -> simd_float4x4 {
        calibration * devicePose
    }

    private let devicePose = simd_float4x4(simd_quatf(angle: 0.3, axis: simd_normalize(SIMD3<Float>(1, 2, 0))))
    private let target = simd_float4x4(simd_quatf(angle: -0.2, axis: SIMD3<Float>(0, 1, 0)))
        .withTranslation(SIMD3<Float>(0.1, 1.2, -0.4))

    // MARK: Tests

    func testFirstUpdateSnapsToTarget() {
        var smoother = CalibrationSmoother()
        let calibration = smoother.update(target: target, devicePose: devicePose, now: 0)
        let emitted = worldPose(calibration, devicePose)
        XCTAssertLessThan(simd_length(position(of: emitted) - position(of: target)), 1e-5)
        XCTAssertLessThan(CalibrationSmoother.angleBetweenDegrees(
            simd_quatf(emitted), simd_quatf(target)), 0.01)
    }

    func testJitterSizedErrorIsHeavilyDamped() {
        var smoother = CalibrationSmoother()
        _ = smoother.update(target: target, devicePose: devicePose, now: 0)

        // A 3 mm / 1° wrist twitch, controller physically still.
        let jitterOffset = SIMD3<Float>(0.003, 0, 0)
        let jittered = (simd_float4x4(simd_quatf(angle: 1 * .pi / 180, axis: SIMD3<Float>(1, 0, 0))) * target)
            .withTranslation(position(of: target) + jitterOffset)
        let calibration = smoother.update(target: jittered, devicePose: devicePose, now: frame)

        let moved = simd_length(position(of: worldPose(calibration, devicePose)) - position(of: target))
        XCTAssertLessThan(moved, 0.003 * 0.1, "jitter should be damped to <10% per frame")
        let rotated = CalibrationSmoother.angleBetweenDegrees(
            simd_quatf(worldPose(calibration, devicePose)), simd_quatf(target))
        XCTAssertLessThan(rotated, 1.0 * 0.1)
    }

    func testLargeErrorCorrectsQuickly() {
        var smoother = CalibrationSmoother()
        _ = smoother.update(target: target, devicePose: devicePose, now: 0)

        // A 6 cm genuine misalignment (above the error ceiling).
        let drifted = target.withTranslation(position(of: target) + SIMD3<Float>(0.06, 0, 0))
        let calibration = smoother.update(target: drifted, devicePose: devicePose, now: frame)

        let moved = simd_length(position(of: worldPose(calibration, devicePose)) - position(of: target))
        XCTAssertGreaterThan(moved, 0.06 * 0.15, "real misalignment should correct >15% per frame")
    }

    func testHugeErrorSnaps() {
        var smoother = CalibrationSmoother()
        _ = smoother.update(target: target, devicePose: devicePose, now: 0)

        let jumped = target.withTranslation(position(of: target) + SIMD3<Float>(0, 0.3, 0))
        let calibration = smoother.update(target: jumped, devicePose: devicePose, now: frame)

        let emitted = worldPose(calibration, devicePose)
        XCTAssertLessThan(simd_length(position(of: emitted) - position(of: jumped)), 1e-5)
    }

    func testCorrectCalibrationAddsNoLagDuringFastMotion() {
        var smoother = CalibrationSmoother()
        let calibration = smoother.update(target: target, devicePose: devicePose, now: 0)

        // Simulate 30 frames of fast motion where the controller's own tracking and
        // the wrist agree (the calibration is correct). Whatever the speed, the
        // emitted pose must match the target exactly — the filter only ever acts on
        // the disagreement, never on the motion itself.
        for step in 1...30 {
            let angle = Float(step) * 0.15
            let movingDevice = transform(
                simd_quatf(angle: angle, axis: simd_normalize(SIMD3<Float>(0, 1, 1))),
                SIMD3<Float>(Float(step) * 0.05, 0, Float(step) * -0.03)  // 4.5 m/s
            )
            let movingTarget = calibration * movingDevice
            let updated = smoother.update(
                target: movingTarget, devicePose: movingDevice, now: Double(step) * frame)

            let emitted = worldPose(updated, movingDevice)
            XCTAssertLessThan(simd_length(position(of: emitted) - position(of: movingTarget)), 1e-4)
            // Tolerance covers float32 matrix-roundtrip accumulation, not filter lag.
            XCTAssertLessThan(CalibrationSmoother.angleBetweenDegrees(
                simd_quatf(emitted), simd_quatf(movingTarget)), 0.25)
        }
    }

    func testBlendFactorRampsWithErrorAndStaysBounded() {
        let dt = Float(frame)
        let atFloor = CalibrationSmoother.blendFactor(
            error: 0.005, floor: 0.005, ceiling: 0.05, dt: dt, slow: 0.4, fast: 0.05)
        let midway = CalibrationSmoother.blendFactor(
            error: 0.02, floor: 0.005, ceiling: 0.05, dt: dt, slow: 0.4, fast: 0.05)
        let atCeiling = CalibrationSmoother.blendFactor(
            error: 0.05, floor: 0.005, ceiling: 0.05, dt: dt, slow: 0.4, fast: 0.05)

        XCTAssertLessThan(atFloor, midway)
        XCTAssertLessThan(midway, atCeiling)
        XCTAssertGreaterThan(atFloor, 0)
        XCTAssertLessThanOrEqual(atCeiling, 1)
    }
}

private extension simd_float4x4 {
    func withTranslation(_ position: SIMD3<Float>) -> simd_float4x4 {
        var copy = self
        copy.columns.3 = SIMD4<Float>(position, 1)
        return copy
    }
}
