import Foundation
import CoreBluetooth
import os

/// The CoreBluetooth bridge that discovers, connects, and reconnects controllers.
/// Owned by a ``SurrealControllerSession``; not part of the public API.
///
/// CoreBluetooth delivers every delegate callback on the dispatch queue supplied at
/// manager creation. All mutable state below is therefore confined to that single
/// serial queue; the async-facing methods hop onto it before touching state. No state
/// is read off-queue, which is what makes the `@unchecked Sendable` conformance sound.
final class SurrealCentral: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.opensurreal.central", qos: .userInitiated)

    private var manager: CBCentralManager!

    private var stateObservers: [UUID: AsyncStream<SurrealBluetoothState>.Continuation] = [:]
    private var discoveryObservers: [UUID: AsyncStream<DiscoveredController>.Continuation] = [:]
    /// Scanning is wanted whenever at least one discovery stream is active.
    private var wantsScan: Bool { !discoveryObservers.isEmpty }

    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var discoveredNames: [UUID: String] = [:]
    private var connectRequests: [UUID: CheckedContinuation<SurrealController, Error>] = [:]
    private var connectedControllers: [UUID: WeakController] = [:]

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: Bluetooth state

    /// An async sequence of Bluetooth availability changes. The current state is
    /// delivered immediately on iteration, followed by every subsequent change.
    func bluetoothStateUpdates() -> AsyncStream<SurrealBluetoothState> {
        let id = UUID()
        return AsyncStream { continuation in
            queue.async {
                self.stateObservers[id] = continuation
                continuation.yield(SurrealBluetoothState(self.manager.state))
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.stateObservers[id] = nil }
            }
        }
    }

    // MARK: Discovery

    /// Scans for Surreal controllers. Scanning starts when iteration begins and
    /// stops when the sequence is cancelled. The same controller may be reported
    /// more than once as its advertisement (and RSSI) updates.
    func discoverControllers() -> AsyncStream<DiscoveredController> {
        let id = UUID()
        return AsyncStream { continuation in
            queue.async {
                self.discoveryObservers[id] = continuation
                self.startScanIfPossible()
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.queue.async {
                    self.discoveryObservers[id] = nil
                    // Stop the radio only once no one is still listening.
                    if self.discoveryObservers.isEmpty, self.manager.state == .poweredOn {
                        self.manager.stopScan()
                    }
                }
            }
        }
    }

    private func startScanIfPossible() {
        guard wantsScan, manager.state == .poweredOn else { return }
        manager.scanForPeripherals(withServices: [SurrealProtocol.serviceUUID], options: nil)
    }

    // MARK: Connection

    /// Connects to (and, if required, pairs with) a controller, performing service /
    /// characteristic discovery and subscribing to its streams. The returned
    /// controller is fully prepared and already streaming.
    func connect(_ controller: DiscoveredController) async throws -> SurrealController {
        try await connectAndPrepare(id: controller.id)
    }

    /// Reconnects the last-connected left and right controllers without scanning,
    /// yielding each as it comes online.
    func connectLastControllers() -> AsyncStream<SurrealController> {
        AsyncStream { continuation in
            let task = Task {
                let ids = await self.retrieve(Self.savedIdentifiers())
                await self.connectAll(ids, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func connectAndPrepare(id: UUID) async throws -> SurrealController {
        let connected = try await connect(id: id)
        do {
            try await connected.prepare()
        } catch {
            await connected.disconnect()
            throw error
        }
        Self.remember(connected.id, handedness: connected.handedness)
        return connected
    }

    private func connectAll(
        _ ids: [UUID],
        into continuation: AsyncStream<SurrealController>.Continuation
    ) async {
        await withTaskGroup(of: SurrealController?.self) { group in
            for id in ids {
                group.addTask { try? await self.connectAndPrepare(id: id) }
            }
            for await controller in group where controller != nil {
                continuation.yield(controller!)
            }
        }
        continuation.finish()
    }

    private func connect(id: UUID) async throws -> SurrealController {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SurrealController, Error>) in
            queue.async {
                guard let peripheral = self.discoveredPeripherals[id] else {
                    continuation.resume(throwing: SurrealError.peripheralNotFound)
                    return
                }
                self.connectRequests[id] = continuation
                self.manager.connect(peripheral, options: nil)
            }
        }
    }

    /// Looks up known peripherals by identifier and records them so ``connect(id:)``
    /// can reach them without a scan. Returns the identifiers actually found.
    private func retrieve(_ identifiers: [UUID]) async -> [UUID] {
        guard !identifiers.isEmpty else { return [] }
        return await withCheckedContinuation { (continuation: CheckedContinuation<[UUID], Never>) in
            queue.async {
                let peripherals = self.manager.retrievePeripherals(withIdentifiers: identifiers)
                for peripheral in peripherals {
                    self.discoveredPeripherals[peripheral.identifier] = peripheral
                    if let name = peripheral.name {
                        self.discoveredNames[peripheral.identifier] = name
                    }
                }
                continuation.resume(returning: peripherals.map(\.identifier))
            }
        }
    }

    // MARK: Last-controller persistence
    //
    // Remembers the most recently connected left and right controller (one slot
    // each) in UserDefaults, so they can be reconnected on a later launch without
    // scanning. A new connection of either hand replaces that hand's saved id.

    private static func remember(_ id: UUID, handedness: Handedness) {
        guard let key = defaultsKey(for: handedness) else { return }
        UserDefaults.standard.set(id.uuidString, forKey: key)
    }

    private static func savedIdentifiers() -> [UUID] {
        [Handedness.left, .right].compactMap { handedness in
            guard let key = defaultsKey(for: handedness),
                  let string = UserDefaults.standard.string(forKey: key)
            else { return nil }
            return UUID(uuidString: string)
        }
    }

    private static func defaultsKey(for handedness: Handedness) -> String? {
        switch handedness {
        case .left: "OpenSurreal.lastLeftController"
        case .right: "OpenSurreal.lastRightController"
        case .unspecified: nil
        }
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = SurrealBluetoothState(central.state)
        for observer in stateObservers.values {
            observer.yield(state)
        }
        if state == .poweredOn {
            startScanIfPossible()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        discoveredPeripherals[peripheral.identifier] = peripheral
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? "Surreal Controller"
        discoveredNames[peripheral.identifier] = name
        let discovered = DiscoveredController(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue
        )
        for observer in discoveryObservers.values { observer.yield(discovered) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let continuation = connectRequests.removeValue(forKey: peripheral.identifier) else { return }
        let name = discoveredNames[peripheral.identifier] ?? peripheral.name ?? "Surreal Controller"
        let controller = SurrealController(peripheral: peripheral, manager: central, queue: queue, name: name)
        connectedControllers[peripheral.identifier] = WeakController(controller)
        continuation.resume(returning: controller)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard let continuation = connectRequests.removeValue(forKey: peripheral.identifier) else { return }
        continuation.resume(throwing: SurrealError.connectionFailed(error?.localizedDescription))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if let continuation = connectRequests.removeValue(forKey: peripheral.identifier) {
            continuation.resume(throwing: SurrealError.connectionFailed(error?.localizedDescription))
        }
        if let weak = connectedControllers.removeValue(forKey: peripheral.identifier) {
            weak.value?.handleDisconnect(error: error)
        }
    }
}
