import Foundation
import Observation

/// A connected controller as managed by a ``SurrealControllerSession``: an
/// observable view model the management UI binds to, plus the per-controller stream
/// forwarding that feeds the session's aggregated streams. Internal — a
/// ``SurrealController`` is a `Sendable` BLE delegate and can't itself be an
/// `@Observable @MainActor` UI model, so this bridges the two.
@MainActor
@Observable
final class ConnectedController: Identifiable {
    let id: UUID
    let name: String
    let handedness: Handedness
    @ObservationIgnored let controller: SurrealController

    /// Whether the controller is currently held (vs set down). Defaults to `true`.
    private(set) var isHeld = true
    /// Whether the controller is still connected. Becomes `false` as it disconnects,
    /// just before it leaves the session's connected list.
    private(set) var isConnected = true

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let onHoldChanged: @MainActor (Handedness, Bool) -> Void
    @ObservationIgnored private let onTerminated: @MainActor (UUID) -> Void

    init(
        controller: SurrealController,
        poses: StreamBroadcaster<ControllerPose>,
        worldPoses: StreamBroadcaster<WorldPose>,
        buttons: StreamBroadcaster<ButtonUpdate>,
        onHoldChanged: @escaping @MainActor (Handedness, Bool) -> Void,
        onTerminated: @escaping @MainActor (UUID) -> Void
    ) {
        self.id = controller.id
        self.name = controller.name
        self.handedness = controller.handedness
        self.controller = controller
        self.onHoldChanged = onHoldChanged
        self.onTerminated = onTerminated
        startForwarding(poses: poses, worldPoses: worldPoses, buttons: buttons)
    }

    private func startForwarding(
        poses: StreamBroadcaster<ControllerPose>,
        worldPoses: StreamBroadcaster<WorldPose>,
        buttons: StreamBroadcaster<ButtonUpdate>
    ) {
        // Each sample already carries its hand, so forwarding is a plain fan-in into
        // the session's aggregated streams. These don't touch `self`, so they end
        // purely when the controller's streams finish (on disconnect).
        let poseStream = controller.poses
        tasks.append(Task {
            for await pose in poseStream { poses.yield(pose) }
        })
        let worldPoseStream = controller.worldPoses
        tasks.append(Task {
            for await pose in worldPoseStream { worldPoses.yield(pose) }
        })
        let buttonStream = controller.buttons
        tasks.append(Task {
            for await update in buttonStream { buttons.yield(update) }
        })

        // Mirror live state for the UI and notify the session of pause/resume and
        // disconnect. These hold `self` weakly, so they end when its streams finish.
        let hand = handedness
        let holdStream = controller.holdState
        let holdChanged = onHoldChanged
        tasks.append(Task { [weak self] in
            for await held in holdStream {
                self?.isHeld = held
                holdChanged(hand, held)
            }
        })
        let cid = id
        let disconnectedStream = controller.disconnected
        let terminate = onTerminated
        tasks.append(Task { [weak self] in
            for await _ in disconnectedStream {
                self?.isConnected = false
                terminate(cid)
            }
        })
    }

    /// Sends a default haptic pulse to the controller.
    func vibrate() {
        Task { try? await controller.vibrate() }
    }

    /// Disconnects the controller.
    func disconnect() {
        Task { await controller.disconnect() }
    }

    func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }
}
