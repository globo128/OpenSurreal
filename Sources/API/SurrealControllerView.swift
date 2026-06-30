#if canImport(SwiftUI)
import SwiftUI

/// A drop-in UI for connecting, pairing, and managing a player's Surreal
/// controllers. Show it for a ``SurrealControllerSession`` and the player can scan,
/// connect, reconnect, and disconnect controllers without you writing any of that
/// flow.
///
/// ```swift
/// @State private var session = SurrealControllerSession()
/// // ...
/// SurrealControllerView(session: session)
/// ```
///
/// The view observes the session, so connected/discovered controllers and Bluetooth
/// state update live. It manages its own navigation chrome; embed it directly in a
/// window or sheet.
public struct SurrealControllerView: View {
    private let session: SurrealControllerSession

    public init(session: SurrealControllerSession) {
        self.session = session
    }

    public var body: some View {
        NavigationStack {
            List {
                bluetoothSection
                if !session.connectedControllers.isEmpty {
                    connectedSection
                }
                discoverySection
                if let error = session.lastError {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Surreal Controllers")
        }
        .onChange(of: session.connectionState, initial: true) { _, state in
            if state == .bothConnected {
                if session.isScanning { session.stopScanning() }
            } else if !session.isScanning {
                session.startScanning()
            }
        }
    }

    // MARK: Bluetooth

    private var bluetoothSection: some View {
        Section("Bluetooth") {
            LabeledContent("Status", value: bluetoothDescription)
            Button(session.isScanning ? "Stop Scanning" : "Scan for Controllers") {
                session.toggleScanning()
            }
            .disabled(session.bluetoothState != .poweredOn)
        }
    }

    private var bluetoothDescription: String {
        switch session.bluetoothState {
        case .poweredOn: "Ready"
        case .poweredOff: "Bluetooth is off"
        case .unauthorized: "Not authorized"
        case .unsupported: "Not supported"
        case .resetting: "Resetting…"
        case .unknown: "Unknown"
        }
    }

    // MARK: Connected

    private var connectedSection: some View {
        Section("Connected") {
            ForEach(session.connectedControllers) { connected in
                ConnectedControllerRow(connected: connected)
            }
        }
    }

    // MARK: Discovery

    private var discoverySection: some View {
        Section("Discovered") {
            if session.discoveredControllers.isEmpty {
                Text(session.isScanning ? "Scanning…" : "No controllers found")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(session.discoveredControllers) { found in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(found.name)
                            Text("RSSI \(found.rssi) dBm")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") { session.connect(found) }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }
}

/// One connected-controller row: hand badge, name, live held state, and quick
/// actions (test haptic + disconnect).
private struct ConnectedControllerRow: View {
    let connected: ConnectedController

    var body: some View {
        HStack(spacing: 12) {
            HandBadge(handedness: connected.handedness)
            VStack(alignment: .leading, spacing: 2) {
                Text(connected.name)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Vibrate") { connected.vibrate() }
                .buttonStyle(.bordered)
            Button("Disconnect", role: .destructive) { connected.disconnect() }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        if !connected.isConnected { return "Disconnecting…" }
        return connected.isHeld ? "Connected" : "Set down"
    }
}

/// A small "L" / "R" capsule for a controller's hand.
private struct HandBadge: View {
    let handedness: Handedness

    var body: some View {
        Text(label)
            .font(.caption.bold())
            .frame(width: 24, height: 24)
            .background(color.opacity(0.25), in: Circle())
            .overlay(Circle().stroke(color, lineWidth: 1))
    }

    private var label: String {
        switch handedness {
        case .left: "L"
        case .right: "R"
        case .unspecified: "?"
        }
    }

    private var color: Color {
        switch handedness {
        case .left: .blue
        case .right: .green
        case .unspecified: .gray
        }
    }
}
#endif
