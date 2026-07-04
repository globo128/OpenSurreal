import simd

/// Smooths the wrist-derived calibration so hand-tracking jitter doesn't shake the
/// emitted world poses, without adding any lag to real motion.
///
/// The controller's own tracking is smooth but drifts; the wrist is globally correct
/// but noisy sample-to-sample. Since `world = calibration · devicePose`, all real
/// motion flows through `devicePose` at full rate — the calibration only encodes the
/// slowly-changing alignment between the two tracking frames. That makes it safe to
/// filter heavily: this blends the calibrated pose toward the wrist target with a
/// time constant that adapts to the size of the disagreement.
///
/// - Small disagreement (millimetres, a degree or two) is tracking noise → long time
///   constant, so jitter is damped hard while holding still.
/// - Large disagreement (controller drifted while coasting, grip shifted) → short
///   time constant, so genuine misalignment corrects within a few frames.
/// - Very large disagreement (fresh pickup, tracking jump) → snap outright.
///
/// Responsiveness is unaffected at any hand speed: while the calibration is correct,
/// the wrist target and the calibrated pose agree no matter how fast the controller
/// moves, the error term stays ~zero, and motion passes through untouched.
struct CalibrationSmoother {
    struct Tuning {
        /// Time constant (s) while the disagreement is at/below the jitter floor.
        var slowTimeConstant: Float = 0.4
        /// Time constant (s) once the disagreement reaches the error ceiling.
        var fastTimeConstant: Float = 0.05
        /// Disagreements at/below these are treated purely as jitter.
        var positionJitterFloor: Float = 0.005
        var rotationJitterFloorDegrees: Float = 1.5
        /// Disagreements at/above these correct at the fast time constant.
        var positionErrorCeiling: Float = 0.05
        var rotationErrorCeilingDegrees: Float = 12
        /// Disagreements beyond these snap immediately.
        var positionSnapThreshold: Float = 0.2
        var rotationSnapThresholdDegrees: Float = 35
    }

    private var calibration: simd_float4x4?
    private var lastUpdate: Double?

    /// Feeds one wrist-derived target pose and returns the smoothed calibration to
    /// register on the controller. `now` must be monotonic (e.g. the anchor-update
    /// timestamp); the first call snaps straight to the target.
    mutating func update(
        target worldFromController: simd_float4x4,
        devicePose: simd_float4x4,
        now: Double,
        tuning: Tuning = Tuning()
    ) -> simd_float4x4 {
        let dt = Float(min(max(now - (lastUpdate ?? now), 0), 0.1))
        lastUpdate = now

        guard let current = calibration else {
            return snap(to: worldFromController, devicePose: devicePose)
        }

        let calibrated = current * devicePose
        let currentPosition = Self.position(of: calibrated)
        let targetPosition = Self.position(of: worldFromController)
        let currentOrientation = simd_quatf(Self.rotation(of: calibrated))
        let targetOrientation = simd_quatf(Self.rotation(of: worldFromController))

        let positionError = simd_length(targetPosition - currentPosition)
        let rotationError = Self.angleBetweenDegrees(currentOrientation, targetOrientation)
        if positionError > tuning.positionSnapThreshold || rotationError > tuning.rotationSnapThresholdDegrees {
            return snap(to: worldFromController, devicePose: devicePose)
        }

        let positionAlpha = Self.blendFactor(
            error: positionError,
            floor: tuning.positionJitterFloor, ceiling: tuning.positionErrorCeiling,
            dt: dt, slow: tuning.slowTimeConstant, fast: tuning.fastTimeConstant
        )
        let rotationAlpha = Self.blendFactor(
            error: rotationError,
            floor: tuning.rotationJitterFloorDegrees, ceiling: tuning.rotationErrorCeilingDegrees,
            dt: dt, slow: tuning.slowTimeConstant, fast: tuning.fastTimeConstant
        )

        let blendedPosition = currentPosition + (targetPosition - currentPosition) * positionAlpha
        let blendedOrientation = simd_slerp(currentOrientation, targetOrientation, rotationAlpha)
        var blended = simd_float4x4(blendedOrientation)
        blended.columns.3 = SIMD4<Float>(blendedPosition, 1)

        let smoothed = blended * devicePose.inverse
        calibration = smoothed
        return smoothed
    }

    private mutating func snap(to worldFromController: simd_float4x4, devicePose: simd_float4x4) -> simd_float4x4 {
        let snapped = worldFromController * devicePose.inverse
        calibration = snapped
        return snapped
    }

    /// Per-update blend fraction: an exponential-smoothing step whose time constant
    /// ramps linearly from `slow` at the jitter floor to `fast` at the error ceiling.
    static func blendFactor(error: Float, floor: Float, ceiling: Float, dt: Float, slow: Float, fast: Float) -> Float {
        let ramp = min(max((error - floor) / max(ceiling - floor, .ulpOfOne), 0), 1)
        let timeConstant = slow + (fast - slow) * ramp
        return 1 - exp(-dt / max(timeConstant, .ulpOfOne))
    }

    static func angleBetweenDegrees(_ a: simd_quatf, _ b: simd_quatf) -> Float {
        let dot = min(abs(simd_dot(simd_normalize(a).vector, simd_normalize(b).vector)), 1)
        return 2 * acos(dot) * (180 / .pi)
    }

    private static func position(of transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    private static func rotation(of transform: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
    }
}
