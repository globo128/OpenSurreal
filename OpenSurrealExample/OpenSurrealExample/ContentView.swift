import SwiftUI
import OpenSurreal

/// The app window. It's just the library's vended ``SurrealControllerView`` — the
/// whole scan / connect / pair / manage flow — plus a tiny bit of glue to open an
/// immersive space whenever a controller is connected so we can render it.
struct ContentView: View {
    let session: SurrealControllerSession
    
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var spaceOpen = false
    
    var body: some View {
        //
        // This view that lets someone manage their connected controllers
        // comes from the OpenSurreal package itself.
        //
        SurrealControllerView(session: session)
            .onChange(of: session.connectionState, initial: true) { _, state in
                openOrCloseImmersiveSpace(for: state)
            }
    }
    
    func openOrCloseImmersiveSpace(for state: SurrealConnectionState) {
        //
        // Automatically open the immersive space when both controllers are connected
        // and automatically close it if the both disconnect.
        //
        Task {
            switch state {
            case .bothConnected:
                if !spaceOpen {
                    if case .opened = await openImmersiveSpace(id: immersiveSpaceID) {
                        spaceOpen = true
                    }
                }
            case .leftConnected, .rightConnected, .connecting:
                break
            case .disconnected:
                if spaceOpen {
                    await dismissImmersiveSpace()
                }
            }
        }
    }
}
