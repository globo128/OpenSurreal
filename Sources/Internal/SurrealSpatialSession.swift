#if os(visionOS)
import Foundation
import ARKit
import simd

/// Aligns Surreal controllers to the headset's world space using ARKit hand
/// tracking, so their world poses line up with what you see. Driven by a
/// ``SurrealControllerSession``; not part of the public API.
///
/// Register controllers with ``track(_:)``; association to a hand is automatic by
/// handedness. The fusion is **wrist-authoritative**: while the matching hand's wrist
/// joint is solidly tracked (and the controller is being held), the wrist owns the
/// world pose. Each ARKit hand update the session:
/// - derives the authoritative world pose from the wrist — its tracked position, and
///   its orientation composed with a fixed per-hand correction so the controller body
///   points the right way,
/// - registers the controller's calibration so `calibration · pose` reproduces that
///   pose, which also means the controller carries on seamlessly from the same place
///   the instant the wrist is lost,
/// - marks the controller hand-authoritative so its world poses report confidence 1.
///
/// When the wrist isn't tracked (or the controller has been set down) the calibration
/// is left frozen and the controller coasts on its own tracking, its world poses
/// reporting the controller's own device confidence.
///
/// Only works inside an `ImmersiveSpace` (hand tracking requires it); the app's
/// Info.plist must declare `NSHandsTrackingUsageDescription`.
@MainActor
final class SurrealSpatialSession {
    enum Status: Sendable, Equatable {
        case idle
        case running
        case unsupported
        case unauthorized
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// Distance (metres) the anchor is pushed forward, along the controller's
    /// pointing direction (−Z), from the tracked wrist joint — so the world pose sits
    /// on the controller's body rather than at the wrist. Retune on device (the wrist
    /// sits further back than the grip).
    var gripForwardOffset: Float = 0.08

    /// Fine **trim** (degrees) applied on top of the built-in per-hand base rotation
    /// that maps the ARKit wrist-joint frame onto the controller body — (pitch about
    /// X, yaw about Y, roll about Z), applied in the controller body frame as
    /// `yaw · pitch · roll`. The base rotation (see ``baseWristOffset(for:)``) already
    /// makes the body −Z point forward; use these to dial in the exact grip (e.g. roll
    /// to level the controller, since roll is about the body's own forward axis).
    /// Default 0.
    var leftWristOrientationOffsetDegrees = SIMD3<Float>(repeating: 0)
    var rightWristOrientationOffsetDegrees = SIMD3<Float>(repeating: 0)

    /// Static heading (yaw) tweak applied about **world up**, per hand, in degrees.
    /// Positive turns the controller's pointing direction toward the player's left.
    /// Defaults toe each controller 5° inward (left turns right, right turns left).
    var leftStaticYawDegrees: Float = -7.5
    var rightStaticYawDegrees: Float = 7.5

    /// Static **world-space** position nudge added to the world pose, per hand, in
    /// metres (world axes: +X = player's right, +Y = up, −Z = forward). Defaults shift
    /// each controller 4 cm inward (left moves right, right moves left).
    var leftStaticPositionOffset = SIMD3<Float>(0.04, 0, 0)
    var rightStaticPositionOffset = SIMD3<Float>(-0.04, 0, 0)

    private let arSession = ARKitSession()
    private let handTracking = HandTrackingProvider()
    private var tracked: [UUID: SurrealController] = [:]
    private var updateTask: Task<Void, Never>?

    // Held/released detection via motion coherence over a short recent window: if the
    // hand moves but the controller doesn't, it isn't being held.
    private var holdBuffers: [UUID: MotionBuffer] = [:]
    private let holdWindow = 45                    // ~0.5 s at 90 Hz
    private let holdMotionThreshold: Float = 0.06  // hand must move ≥6 cm to judge
    private let holdRatioThreshold: Float = 0.6    // controller must move ≥60% as far

    private struct MotionBuffer {
        var controllerPositions: [SIMD3<Float>] = []
        var handPositions: [SIMD3<Float>] = []
    }

    init() {}

    /// Begins tracking the given controller. Association to a hand is by handedness;
    /// controllers with unspecified handedness match any hand.
    func track(_ controller: SurrealController) {
        tracked[controller.id] = controller
    }

    /// Stops tracking the controller and clears its calibration.
    func untrack(_ controller: SurrealController) {
        tracked[controller.id] = nil
        holdBuffers[controller.id] = nil
        controller.setHandAuthoritative(false)
        controller.clearCalibration()
    }

    /// Requests hand-tracking authorization and starts the ARKit session. Inspect
    /// ``status`` afterward. Safe to call repeatedly — a no-op once already running, so
    /// it never spawns a second consumer task or restarts the provider.
    func start() async {
        guard status != .running else { return }
        guard HandTrackingProvider.isSupported else {
            status = .unsupported
            return
        }
        let authorization = await arSession.requestAuthorization(for: [.handTracking])
        guard authorization[.handTracking] == .allowed else {
            status = .unauthorized
            return
        }
        do {
            try await arSession.run([handTracking])
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        status = .running
        updateTask = Task { [weak self] in
            await self?.consumeHandUpdates()
        }
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
        arSession.stop()
        status = .idle
    }

    private func consumeHandUpdates() async {
        for await update in handTracking.anchorUpdates {
            let hand = update.anchor
            let chirality: Handedness = hand.chirality == .left ? .left : .right
            guard let controller = tracked.values.first(where: { $0.handedness == chirality })
                ?? tracked.values.first(where: { $0.handedness == .unspecified })
            else { continue }

            // The wrist must be solidly tracked to be authoritative. Otherwise leave
            // the calibration frozen so the controller coasts on its own tracking from
            // the last wrist-anchored pose, reporting its own device confidence.
            guard update.event != .removed,
                  hand.isTracked,
                  let pose = controller.latestPose,
                  let wristTransform = wristWorldTransform(hand)
            else {
                controller.setHandAuthoritative(false)
                continue
            }

            let wristPosition = SIMD3<Float>(
                wristTransform.columns.3.x, wristTransform.columns.3.y, wristTransform.columns.3.z
            )
            let wristOrientation = simd_quatf(rotation(of: wristTransform))

            // Held/released detection: if the hand moves but the controller doesn't,
            // it's been set down — pause authority so the pose doesn't chase the empty
            // hand, leaving the controller frozen where it sits.
            accumulateHold(controllerID: controller.id, controllerPosition: pose.position, handPosition: wristPosition)
            if let held = detectHeld(controllerID: controller.id) {
                controller.setHeld(held)
            }
            guard controller.isHeld else {
                controller.setHandAuthoritative(false)
                continue
            }

            // The wrist is authoritative. Build the world pose from it — position from
            // the wrist (pushed forward onto the controller body, plus a static world
            // nudge), orientation from the wrist composed with the fixed correction and
            // a static heading tweak about world up — and register the calibration so
            // `calibration · pose` reproduces it. Because the calibration is exact, the
            // controller carries on from this same pose the instant the wrist drops.
            let orientation = staticYawAdjustment(for: controller.handedness)
                * wristOrientation
                * orientationOffset(for: controller.handedness)
            let forward = orientation.act(SIMD3<Float>(0, 0, -1))
            let position = wristPosition
                + forward * gripForwardOffset
                + staticPositionOffset(for: controller.handedness)

            var worldFromController = simd_float4x4(orientation)
            worldFromController.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
            controller.setCalibration(worldFromController * pose.matrix.inverse)
            controller.setHandAuthoritative(true)
        }
    }

    /// World transform of the wrist joint, or nil if the skeleton/joint isn't tracked.
    private func wristWorldTransform(_ hand: HandAnchor) -> simd_float4x4? {
        guard let skeleton = hand.handSkeleton else { return nil }
        let wrist = skeleton.joint(.wrist)
        guard wrist.isTracked else { return nil }
        return hand.originFromAnchorTransform * wrist.anchorFromJointTransform
    }

    /// Static heading tweak about world up, per hand. See ``leftStaticYawDegrees``.
    private func staticYawAdjustment(for handedness: Handedness) -> simd_quatf {
        let degrees = handedness == .left ? leftStaticYawDegrees : rightStaticYawDegrees
        return simd_quatf(angle: degrees * (.pi / 180), axis: [0, 1, 0])
    }

    /// Static world-space position nudge, per hand. See ``leftStaticPositionOffset``.
    private func staticPositionOffset(for handedness: Handedness) -> SIMD3<Float> {
        handedness == .left ? leftStaticPositionOffset : rightStaticPositionOffset
    }

    /// Fixed rotation from the wrist-joint frame to the controller body frame, per
    /// hand: the measured base rotation followed by the fine Euler trim. See
    /// ``leftWristOrientationOffsetDegrees`` / ``rightWristOrientationOffsetDegrees``.
    private func orientationOffset(for handedness: Handedness) -> simd_quatf {
        let degrees = handedness == .left ? leftWristOrientationOffsetDegrees : rightWristOrientationOffsetDegrees
        let radians = degrees * (.pi / 180)
        let pitch = simd_quatf(angle: radians.x, axis: [1, 0, 0])
        let yaw = simd_quatf(angle: radians.y, axis: [0, 1, 0])
        let roll = simd_quatf(angle: radians.z, axis: [0, 0, 1])
        return baseWristOffset(for: handedness) * (yaw * pitch * roll)
    }

    /// Base rotation mapping the ARKit wrist-joint frame onto the controller body
    /// frame, so the body's −Z points where the controller points. Measured on device
    /// (the wrist frames differ between hands):
    /// - left wrist:  local +X → forward (−Z), +Y → right (+X), +Z → down (−Y)
    /// - right wrist: local −X → forward (−Z), +Y → right (+X), +Z → up (+Y)
    ///
    /// Each is `wristToBody = bodyOrientation · wristOrientation⁻¹` captured with the
    /// controller held pointing forward and level, expressed as the wrist→body basis.
    private func baseWristOffset(for handedness: Handedness) -> simd_quatf {
        let basis: simd_float3x3
        switch handedness {
        case .left:
            basis = simd_float3x3(columns: (
                SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, -1), SIMD3<Float>(-1, 0, 0)
            ))
        case .right, .unspecified:
            basis = simd_float3x3(columns: (
                SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 0)
            ))
        }
        return simd_quatf(basis)
    }

    /// The rotation (3×3) part of a rigid 4×4 transform.
    private func rotation(of transform: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
    }

    private func accumulateHold(controllerID: UUID, controllerPosition: SIMD3<Float>, handPosition: SIMD3<Float>) {
        var buffer = holdBuffers[controllerID] ?? MotionBuffer()
        buffer.controllerPositions.append(controllerPosition)
        buffer.handPositions.append(handPosition)
        if buffer.controllerPositions.count > holdWindow {
            buffer.controllerPositions.removeFirst()
            buffer.handPositions.removeFirst()
        }
        holdBuffers[controllerID] = buffer
    }

    /// Held if, over the recent window, the controller moved a comparable amount to
    /// the hand. Returns nil (indeterminate) when the hand barely moved.
    private func detectHeld(controllerID: UUID) -> Bool? {
        guard let buffer = holdBuffers[controllerID], buffer.handPositions.count >= 15 else { return nil }
        let handSpread = spread3D(buffer.handPositions)
        guard handSpread >= holdMotionThreshold else { return nil }
        let controllerSpread = spread3D(buffer.controllerPositions)
        return controllerSpread >= holdRatioThreshold * handSpread
    }

    /// Diagonal of the 3D bounding box of a set of positions.
    private func spread3D(_ positions: [SIMD3<Float>]) -> Float {
        guard let first = positions.first else { return 0 }
        var lo = first, hi = first
        for p in positions {
            lo.x = Swift.min(lo.x, p.x); lo.y = Swift.min(lo.y, p.y); lo.z = Swift.min(lo.z, p.z)
            hi.x = Swift.max(hi.x, p.x); hi.y = Swift.max(hi.y, p.y); hi.z = Swift.max(hi.z, p.z)
        }
        return length(hi - lo)
    }
}
#endif
