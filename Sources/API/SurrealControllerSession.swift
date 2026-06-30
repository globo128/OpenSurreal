import Foundation
import Observation

/// The single entry point to OpenSurreal: it manages a player's Surreal controllers
/// for you and surfaces their input as a handful of async streams.
///
/// Create one, show ``SurrealControllerView`` for the management UI, and read input
/// from the streams — there are no controller objects to juggle:
///
/// ```swift
/// let session = SurrealControllerSession()
///
/// // The whole connect / pair / manage flow:
/// SurrealControllerView(session: session)
///
/// // Connection state — observe events and/or inspect the current value:
/// for await event in session.stateUpdates {
///     switch event {
///     case .connection(let state): …          // .bothConnected, .leftConnected, …
///     case .paused(let hand): …                // controller set down
///     case .resumed(let hand): …               // picked up again
///     }
/// }
///
/// // Calibrated world poses (visionOS), each tagged with its hand:
/// for await pose in session.worldPoseUpdates {
///     place(pose.handedness, pose.position, pose.orientation)
/// }
/// ```
@MainActor
@Observable
public final class SurrealControllerSession {
    /// The session's current connection state. Updated live; observe changes as
    /// ``SurrealControllerEvent/connection(_:)`` on ``stateUpdates``.
    public private(set) var connectionState: SurrealConnectionState = .disconnected

    @ObservationIgnored let central: SurrealCentral

    /// The host's Bluetooth availability. Scanning and connecting only work once this
    /// is ``SurrealBluetoothState/poweredOn``.
    public private(set) var bluetoothState: SurrealBluetoothState = .unknown
    /// Whether a scan for nearby controllers is currently running.
    public private(set) var isScanning = false
    /// Controllers found by the current scan and not yet connected. Pass one to
    /// ``connect(_:)``.
    public private(set) var discoveredControllers: [DiscoveredController] = []
    /// A human-readable description of the most recent connection failure, if any.
    public private(set) var lastError: String?

    // Connected controllers as observable row models for the bundled view. Internal —
    // the public surface exposes what's connected via `connectionState` and the streams.
    private(set) var connectedControllers: [ConnectedController] = []

    @ObservationIgnored private let poseBroadcaster = StreamBroadcaster<ControllerPose>(bufferSize: 32)
    @ObservationIgnored private let worldPoseBroadcaster = StreamBroadcaster<WorldPose>(bufferSize: 32)
    @ObservationIgnored private let buttonBroadcaster = StreamBroadcaster<ButtonUpdate>(bufferSize: 64)
    @ObservationIgnored private let stateBroadcaster = StreamBroadcaster<SurrealControllerEvent>(bufferSize: 16)

    @ObservationIgnored private let autoReconnect: Bool
    @ObservationIgnored private var didAutoReconnect = false
    @ObservationIgnored private var isConnecting = false
    @ObservationIgnored private var bluetoothTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    #if os(visionOS)
    @ObservationIgnored private let spatial = SurrealSpatialSession()
    /// The current state of spatial (hand-tracking) alignment. `.running` means
    /// ``worldPoseUpdates`` will flow once controllers calibrate; the other cases tell
    /// you why it won't (unsupported device, denied authorization, ARKit error).
    public private(set) var spatialTrackingStatus: SpatialTrackingStatus = .notStarted
    #endif

    /// Creates a session and begins observing the Bluetooth radio.
    ///
    /// - Parameter autoReconnectLastControllers: When `true` (the default), the
    ///   session reconnects the last-used left/right controllers the first time
    ///   Bluetooth powers on — no scan, no UI needed.
    public init(autoReconnectLastControllers: Bool = true) {
        self.central = SurrealCentral()
        self.autoReconnect = autoReconnectLastControllers
        observeBluetooth()
    }

    // MARK: Public streams

    /// Connection-state changes and pause/resume events. A fresh, independent
    /// subscription is created per access, and immediately replays the current
    /// connection state as a ``SurrealControllerEvent/connection(_:)`` — so a
    /// subscriber that attaches after the controllers connected (e.g. auto-reconnect,
    /// which runs at launch) still learns the current state instead of waiting for the
    /// next change. Pause/resume events remain future-only.
    public var stateUpdates: AsyncStream<SurrealControllerEvent> {
        stateBroadcaster.stream(initial: .connection(connectionState))
    }

    /// Controller-frame 6DOF poses from every connected controller, each tagged with
    /// its hand. For world-anchored poses on visionOS, use ``worldPoseUpdates``.
    public var poseUpdates: AsyncStream<ControllerPose> { poseBroadcaster.stream() }

    /// World-space poses from every connected controller, each tagged with its hand.
    /// Emits only while spatial tracking is running (see ``startSpatialTracking()``).
    public var worldPoseUpdates: AsyncStream<WorldPose> { worldPoseBroadcaster.stream() }

    /// Button/trigger/joystick snapshots from every connected controller, each
    /// tagged with its hand.
    public var buttonUpdates: AsyncStream<ButtonUpdate> { buttonBroadcaster.stream() }

    // MARK: Connection state

    private func setConnecting(_ value: Bool) {
        guard isConnecting != value else { return }
        isConnecting = value
        recomputeConnectionState()
    }

    private func recomputeConnectionState() {
        let new: SurrealConnectionState
        if connectedControllers.count >= 2 {
            new = .bothConnected
        } else if let only = connectedControllers.first {
            new = only.handedness == .right ? .rightConnected : .leftConnected
        } else if isConnecting {
            new = .connecting
        } else {
            new = .disconnected
        }
        guard new != connectionState else { return }
        connectionState = new
        stateBroadcaster.yield(.connection(new))
    }

    private func handleHoldChange(_ hand: Handedness, _ held: Bool) {
        stateBroadcaster.yield(held ? .resumed(hand) : .paused(hand))
    }

    // MARK: Bluetooth

    private func observeBluetooth() {
        bluetoothTask = Task { [weak self] in
            guard let self else { return }
            for await state in self.central.bluetoothStateUpdates() {
                self.bluetoothState = state
                if state == .poweredOn {
                    if self.autoReconnect, !self.didAutoReconnect {
                        self.didAutoReconnect = true
                        self.reconnectLastControllers()
                    }
                } else {
                    self.isScanning = false
                }
            }
        }
    }

    // MARK: Scanning

    func toggleScanning() {
        if isScanning { stopScanning() } else { startScanning() }
    }

    /// Starts scanning for nearby controllers; results appear in
    /// ``discoveredControllers``. A no-op while already scanning. The scan begins as
    /// soon as Bluetooth is powered on, so it's safe to call before then.
    public func startScanning() {
        guard !isScanning else { return }
        isScanning = true
        lastError = nil
        discoveredControllers.removeAll()
        scanTask = Task { [weak self] in
            guard let self else { return }
            for await found in self.central.discoverControllers() {
                self.handleDiscovery(found)
            }
        }
    }

    /// Stops the current scan. ``discoveredControllers`` keeps its last results.
    public func stopScanning() {
        isScanning = false
        scanTask?.cancel()
        scanTask = nil
    }

    private func handleDiscovery(_ found: DiscoveredController) {
        guard !connectedControllers.contains(where: { $0.id == found.id }) else { return }
        if let index = discoveredControllers.firstIndex(where: { $0.id == found.id }) {
            discoveredControllers[index] = found
        } else {
            discoveredControllers.append(found)
        }
    }

    // MARK: Connection

    /// Connects to a controller found by scanning. Progress is reflected in
    /// ``connectionState``; a failure is described in ``lastError``.
    public func connect(_ found: DiscoveredController) {
        discoveredControllers.removeAll { $0.id == found.id }
        setConnecting(true)
        Task { [weak self] in
            guard let self else { return }
            do {
                let controller = try await self.central.connect(found)
                self.adopt(controller)
            } catch {
                self.lastError = "Couldn't connect to \(found.name): \(error)"
            }
            self.setConnecting(false)
        }
    }

    /// Reconnects the last-used left/right controllers without scanning. Runs
    /// automatically the first time Bluetooth powers on unless you opted out with
    /// `init(autoReconnectLastControllers: false)`.
    public func reconnectLastControllers() {
        setConnecting(true)
        Task { [weak self] in
            guard let self else { return }
            for await controller in self.central.connectLastControllers() {
                self.adopt(controller)
            }
            self.setConnecting(false)
        }
    }

    /// Disconnects the connected controller for the given hand, if one is connected.
    /// ``connectionState`` updates once the link is torn down.
    public func disconnect(_ handedness: Handedness) {
        for connected in connectedControllers where connected.handedness == handedness {
            connected.disconnect()
        }
    }

    /// Disconnects every connected controller.
    public func disconnectAll() {
        for connected in connectedControllers { connected.disconnect() }
    }

    private func adopt(_ controller: SurrealController) {
        guard !connectedControllers.contains(where: { $0.id == controller.id }) else { return }
        let connected = ConnectedController(
            controller: controller,
            poses: poseBroadcaster,
            worldPoses: worldPoseBroadcaster,
            buttons: buttonBroadcaster,
            onHoldChanged: { [weak self] hand, held in self?.handleHoldChange(hand, held) },
            onTerminated: { [weak self] id in self?.remove(id: id) }
        )
        connectedControllers.append(connected)
        #if os(visionOS)
        spatial.track(controller)
        #endif
        recomputeConnectionState()
    }

    private func remove(id: UUID) {
        guard let connected = connectedControllers.first(where: { $0.id == id }) else { return }
        #if os(visionOS)
        spatial.untrack(connected.controller)
        #endif
        connected.stop()
        connectedControllers.removeAll { $0.id == id }
        recomputeConnectionState()
    }

    // MARK: World tracking (visionOS)

    #if os(visionOS)
    /// Starts ARKit hand tracking so connected controllers calibrate into the
    /// headset's world space and begin emitting on ``worldPoseUpdates``.
    ///
    /// Call this when your `ImmersiveSpace` content appears (hand tracking requires
    /// being inside one); pair it with ``stopSpatialTracking()`` on disappear. All
    /// currently-connected controllers are tracked automatically, as are any that
    /// connect later. Safe to call more than once.
    ///
    /// - Returns: the resulting ``SpatialTrackingStatus`` — check it (or observe
    ///   ``spatialTrackingStatus``) to confirm tracking actually started; anything
    ///   other than `.running` means world poses won't flow.
    @discardableResult
    public func startSpatialTracking() async -> SpatialTrackingStatus {
        await spatial.start()
        spatialTrackingStatus = SpatialTrackingStatus(spatial.status)
        for connected in connectedControllers { spatial.track(connected.controller) }
        return spatialTrackingStatus
    }

    /// Stops ARKit hand tracking. ``worldPoseUpdates`` stops emitting; controller-
    /// frame ``poseUpdates`` are unaffected.
    public func stopSpatialTracking() {
        spatial.stop()
        spatialTrackingStatus = SpatialTrackingStatus(spatial.status)
    }
    #endif

    // MARK: Lifecycle

    /// Tears the session down: cancels its background tasks, stops spatial tracking,
    /// and disconnects every controller. Optional for an app-lifetime session — useful
    /// for tests or transient sessions. Create a fresh session to start again.
    public func stop() {
        bluetoothTask?.cancel(); bluetoothTask = nil
        scanTask?.cancel(); scanTask = nil
        isScanning = false
        isConnecting = false
        discoveredControllers.removeAll()
        #if os(visionOS)
        spatial.stop()
        spatialTrackingStatus = SpatialTrackingStatus(spatial.status)
        #endif
        for connected in connectedControllers {
            #if os(visionOS)
            spatial.untrack(connected.controller)
            #endif
            connected.disconnect()
            connected.stop()
        }
        connectedControllers.removeAll()
        recomputeConnectionState()
    }
}
