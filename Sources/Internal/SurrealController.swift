import Foundation
import CoreBluetooth
import simd
import os

/// A connected Surreal controller. Created by ``SurrealCentral`` and driven by a
/// ``SurrealControllerSession``; not part of the public API.
///
/// Pose and button data are delivered as `AsyncStream`s that finish when the
/// controller disconnects. The controller knows its own ``handedness``, so it tags
/// every sample it emits.
///
/// All mutable state is confined to the CoreBluetooth delegate queue, which
/// justifies the `@unchecked Sendable` conformance.
final class SurrealController: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    /// Stable per-device identifier assigned by CoreBluetooth on this host.
    let id: UUID
    /// The controller's name, if known.
    let name: String
    /// Which hand this controller is, parsed from ``name``.
    let handedness: Handedness

    /// 6DOF pose samples in the controller's own tracking frame. Buffers only the
    /// newest value. Finishes on disconnect.
    let poses: AsyncStream<ControllerPose>
    /// Pose samples transformed into the headset's **world** coordinate space. Empty
    /// until a calibration is set; thereafter updates at the pose rate. Finishes on
    /// disconnect.
    let worldPoses: AsyncStream<WorldPose>
    /// Button/trigger/joystick snapshots. Finishes on disconnect.
    let buttons: AsyncStream<ButtonUpdate>
    /// Battery-level readings (percentage), from the standard Battery Service. Emits
    /// once on connect (initial read) and again whenever the level changes. Buffers
    /// only the newest value. Empty if the controller lacks the service. Finishes on
    /// disconnect.
    let battery: AsyncStream<BatteryUpdate>
    /// Yields once when the link drops, then finishes. (Connection success is
    /// implied by ``SurrealCentral/connect(_:)`` returning.)
    let disconnected: AsyncStream<Void>
    /// Emits whenever the held/released state changes (a spatial session infers this
    /// from whether the controller and hand move together). `true` = held.
    let holdState: AsyncStream<Bool>

    private let peripheral: CBPeripheral
    private let manager: CBCentralManager
    private let queue: DispatchQueue

    private let poseContinuation: AsyncStream<ControllerPose>.Continuation
    private let worldPoseContinuation: AsyncStream<WorldPose>.Continuation
    private let buttonContinuation: AsyncStream<ButtonUpdate>.Continuation
    private let batteryContinuation: AsyncStream<BatteryUpdate>.Continuation
    private let disconnectedContinuation: AsyncStream<Void>.Continuation
    private let holdStateContinuation: AsyncStream<Bool>.Continuation

    // Lock-backed spatial state — readable/writable from any thread (the BLE queue
    // produces poses; a spatial session updates the calibration).
    private let calibrationStore = OSAllocatedUnfairLock<simd_float4x4?>(initialState: nil)
    private let latestPoseStore = OSAllocatedUnfairLock<ControllerPose?>(initialState: nil)
    private let isHeldStore = OSAllocatedUnfairLock<Bool>(initialState: true)
    private let handAuthoritativeStore = OSAllocatedUnfairLock<Bool>(initialState: false)

    private static let log = Logger(subsystem: "OpenSurreal", category: "Fusion")

    // All of the following are touched only on `queue`.
    private var poseCharacteristic: CBCharacteristic?
    private var buttonCharacteristic: CBCharacteristic?
    private var vibrationCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    private var vibrationSequence: UInt16 = 0
    private var prepareContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []
    private var isFinished = false

    init(peripheral: CBPeripheral, manager: CBCentralManager, queue: DispatchQueue, name: String) {
        self.id = peripheral.identifier
        self.name = name
        self.handedness = Handedness(name: name)
        self.peripheral = peripheral
        self.manager = manager
        self.queue = queue

        var poseCont: AsyncStream<ControllerPose>.Continuation!
        poses = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { poseCont = $0 }
        poseContinuation = poseCont

        var worldPoseCont: AsyncStream<WorldPose>.Continuation!
        worldPoses = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { worldPoseCont = $0 }
        worldPoseContinuation = worldPoseCont

        var buttonCont: AsyncStream<ButtonUpdate>.Continuation!
        buttons = AsyncStream(bufferingPolicy: .bufferingNewest(32)) { buttonCont = $0 }
        buttonContinuation = buttonCont

        var batteryCont: AsyncStream<BatteryUpdate>.Continuation!
        battery = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { batteryCont = $0 }
        batteryContinuation = batteryCont

        var disconnectedCont: AsyncStream<Void>.Continuation!
        disconnected = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { disconnectedCont = $0 }
        disconnectedContinuation = disconnectedCont

        var holdCont: AsyncStream<Bool>.Continuation!
        holdState = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { holdCont = $0 }
        holdStateContinuation = holdCont

        super.init()
    }

    // MARK: Setup (called by the central after the BLE link is up)

    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.prepareContinuation = continuation
                self.peripheral.delegate = self
                self.peripheral.discoverServices([
                    SurrealProtocol.serviceUUID,
                    SurrealProtocol.batteryServiceUUID
                ])
            }
        }
    }

    // MARK: Spatial calibration

    /// The most recent controller-frame pose, or nil if none has arrived yet.
    var latestPose: ControllerPose? { latestPoseStore.withLock { $0 } }

    /// The calibration transform (`worldFromControllerFrame`) currently applied to
    /// produce ``worldPoses``, or nil if uncalibrated.
    var calibration: simd_float4x4? { calibrationStore.withLock { $0 } }

    /// Whether the controller is currently held (vs set down). Inferred by a spatial
    /// session from motion coherence; defaults to `true`.
    var isHeld: Bool { isHeldStore.withLock { $0 } }

    /// Updates whether the headset's hand tracking currently has a solid lock on this
    /// controller's wrist, making the wrist authoritative for the world pose. A spatial
    /// session calls this as the wrist lock comes and goes; while authoritative, emitted
    /// ``worldPoses`` report confidence `1.0`, otherwise the controller's own device
    /// confidence. Logs each transition.
    func setHandAuthoritative(_ authoritative: Bool) {
        let changed = handAuthoritativeStore.withLock { current -> Bool in
            guard current != authoritative else { return false }
            current = authoritative
            return true
        }
        guard changed else { return }
        Self.log.info(
            "World-pose authority for \(self.name, privacy: .public): now \(authoritative ? "WRIST (hand tracking)" : "DEVICE (controller)", privacy: .public)"
        )
    }

    /// Updates the held/released state; emits on ``holdState`` only when it changes.
    func setHeld(_ held: Bool) {
        let changed = isHeldStore.withLock { current -> Bool in
            guard current != held else { return false }
            current = held
            return true
        }
        if changed { holdStateContinuation.yield(held) }
    }

    /// Sets the calibration that maps the controller's tracking frame into the
    /// headset world frame. Subsequent samples are emitted on ``worldPoses``.
    /// Thread-safe; a spatial session may call this continuously to correct drift.
    func setCalibration(_ worldFromControllerFrame: simd_float4x4) {
        calibrationStore.withLock { $0 = worldFromControllerFrame }
    }

    /// Clears the calibration; ``worldPoses`` stops emitting until one is set again.
    func clearCalibration() {
        calibrationStore.withLock { $0 = nil }
    }

    // MARK: Haptics

    /// Sends a haptic vibration command and waits for the device to acknowledge it.
    ///
    /// - Parameters:
    ///   - amplitude: Vibration strength, `0...10000`.
    ///   - frequency: Vibration frequency in Hz, `20...300`.
    ///   - duration: Vibration duration; must be at least 30 ms.
    func vibrate(
        amplitude: UInt16 = 5000,
        frequency: UInt16 = 100,
        duration: Duration = .milliseconds(200)
    ) async throws {
        guard (0...10000).contains(amplitude) else {
            throw SurrealError.invalidParameter("amplitude must be in 0...10000")
        }
        guard (20...300).contains(frequency) else {
            throw SurrealError.invalidParameter("frequency must be in 20...300 Hz")
        }
        let milliseconds = duration.inMilliseconds
        guard milliseconds >= 30 else {
            throw SurrealError.invalidParameter("duration must be at least 30 ms")
        }
        let durationMs = UInt32(min(milliseconds, UInt64(UInt32.max)))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                // Bail (resuming the continuation) if the link is gone. Writing to a
                // disconnected peripheral is an API misuse, and on the `.withResponse`
                // path below it would never get a delegate callback to resume on —
                // leaking the continuation, since `handleDisconnect` has already run.
                guard !self.isFinished,
                      self.peripheral.state == .connected,
                      let characteristic = self.vibrationCharacteristic else {
                    continuation.resume(throwing: SurrealError.notConnected)
                    return
                }
                // A response-based write is already in flight; don't clobber its
                // pending continuation (that would leak it). The device is already
                // buzzing, so treat an overlapping request as a no-op success.
                guard self.writeContinuation == nil else {
                    continuation.resume()
                    return
                }
                let sequence = self.vibrationSequence
                self.vibrationSequence = self.vibrationSequence &+ 1
                let packet = SurrealProtocol.encodeVibration(
                    sequence: sequence,
                    amplitude: amplitude,
                    frequency: frequency,
                    durationMs: durationMs
                )
                if characteristic.properties.contains(.write) {
                    self.writeContinuation = continuation
                    self.peripheral.writeValue(packet, for: characteristic, type: .withResponse)
                } else {
                    self.peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
                    continuation.resume()
                }
            }
        }
    }

    /// Disconnects the controller and waits until the link is fully torn down.
    func disconnect() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.isFinished {
                    continuation.resume()
                    return
                }
                self.disconnectWaiters.append(continuation)
                self.manager.cancelPeripheralConnection(self.peripheral)
            }
        }
    }

    // MARK: Disconnect handling (called on `queue` by the central)

    func handleDisconnect(error: Error?) {
        guard !isFinished else { return }
        isFinished = true

        let reason = error?.localizedDescription
        poseContinuation.finish()
        worldPoseContinuation.finish()
        buttonContinuation.finish()
        batteryContinuation.finish()
        holdStateContinuation.finish()
        disconnectedContinuation.yield(())
        disconnectedContinuation.finish()

        if let continuation = prepareContinuation {
            prepareContinuation = nil
            continuation.resume(throwing: SurrealError.disconnected(reason))
        }
        if let continuation = writeContinuation {
            writeContinuation = nil
            continuation.resume(throwing: SurrealError.disconnected(reason))
        }
        let waiters = disconnectWaiters
        disconnectWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func finishPrepare(throwing error: SurrealError?) {
        guard let continuation = prepareContinuation else { return }
        prepareContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            finishPrepare(throwing: .connectionFailed(error.localizedDescription))
            return
        }
        let services = peripheral.services ?? []
        guard let surreal = services.first(where: { $0.uuid == SurrealProtocol.serviceUUID }) else {
            finishPrepare(throwing: .serviceNotFound)
            return
        }
        peripheral.discoverCharacteristics(
            [
                SurrealProtocol.poseCharacteristicUUID,
                SurrealProtocol.buttonCharacteristicUUID,
                SurrealProtocol.vibrationCharacteristicUUID
            ],
            for: surreal
        )
        // The standard Battery Service is optional — its absence must never block
        // controller readiness, so it's discovered independently of the Surreal service.
        if let battery = services.first(where: { $0.uuid == SurrealProtocol.batteryServiceUUID }) {
            peripheral.discoverCharacteristics([SurrealProtocol.batteryLevelCharacteristicUUID], for: battery)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        // This delegate fires once per service. The Battery Service is optional and
        // independent of controller readiness: handle it on its own and never let a
        // failure (or its ordering relative to the Surreal service) fail `prepare`.
        if service.uuid == SurrealProtocol.batteryServiceUUID {
            guard error == nil else { return }
            for characteristic in service.characteristics ?? []
            where characteristic.uuid == SurrealProtocol.batteryLevelCharacteristicUUID {
                batteryCharacteristic = characteristic
                // Subscribe for live changes, and kick off a one-shot read for the
                // current level — notify alone won't deliver a value until the level
                // next changes.
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            }
            return
        }

        if let error {
            finishPrepare(throwing: .connectionFailed(error.localizedDescription))
            return
        }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case SurrealProtocol.poseCharacteristicUUID:
                poseCharacteristic = characteristic
            case SurrealProtocol.buttonCharacteristicUUID:
                buttonCharacteristic = characteristic
            case SurrealProtocol.vibrationCharacteristicUUID:
                vibrationCharacteristic = characteristic
            default:
                break
            }
        }
        guard let pose = poseCharacteristic, let button = buttonCharacteristic else {
            finishPrepare(throwing: .characteristicsNotFound)
            return
        }
        peripheral.setNotifyValue(true, for: pose)
        peripheral.setNotifyValue(true, for: button)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            finishPrepare(throwing: .connectionFailed(error.localizedDescription))
            return
        }
        if let pose = poseCharacteristic, let button = buttonCharacteristic,
           pose.isNotifying, button.isNotifying {
            finishPrepare(throwing: nil)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case SurrealProtocol.poseCharacteristicUUID:
            if let pose = try? ControllerPose(packet: data, handedness: handedness) {
                poseContinuation.yield(pose)
                latestPoseStore.withLock { $0 = pose }
                if let calibration = calibrationStore.withLock({ $0 }) {
                    // Velocities are in the controller frame; rotate (not translate)
                    // them into world axes by the calibration's rotation part. The
                    // calibration is always a rigid rotation+translation, so its 3×3
                    // is a pure rotation.
                    let rotation = simd_float3x3(
                        SIMD3(calibration.columns.0.x, calibration.columns.0.y, calibration.columns.0.z),
                        SIMD3(calibration.columns.1.x, calibration.columns.1.y, calibration.columns.1.z),
                        SIMD3(calibration.columns.2.x, calibration.columns.2.y, calibration.columns.2.z)
                    )
                    // While the wrist is authoritative the calibration is refreshed
                    // from it every frame, so `calibration · pose` is the wrist pose;
                    // report full confidence. Otherwise the controller is coasting on
                    // its own tracking — pass its device confidence through.
                    let confidence = handAuthoritativeStore.withLock { $0 } ? 1.0 : pose.confidence
                    let world = WorldPose(
                        handedness: handedness,
                        transform: calibration * pose.matrix,
                        timestamp: pose.timestamp,
                        confidence: confidence,
                        linearVelocity: rotation * pose.linearVelocity,
                        angularVelocity: rotation * pose.angularVelocity,
                        acceleration: rotation * pose.acceleration
                    )
                    worldPoseContinuation.yield(world)
                }
            }
        case SurrealProtocol.buttonCharacteristicUUID:
            if let update = try? ButtonUpdate(packet: data, handedness: handedness) {
                buttonContinuation.yield(update)
            }
        case SurrealProtocol.batteryLevelCharacteristicUUID:
            // Delivered both by the one-shot read on connect and by later notifications.
            if let update = try? BatteryUpdate(packet: data, handedness: handedness) {
                batteryContinuation.yield(update)
            }
        default:
            break
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let continuation = writeContinuation else { return }
        writeContinuation = nil
        if let error {
            continuation.resume(throwing: SurrealError.connectionFailed(error.localizedDescription))
        } else {
            continuation.resume()
        }
    }
}
