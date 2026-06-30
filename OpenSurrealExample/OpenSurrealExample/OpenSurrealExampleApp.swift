import SwiftUI
import OpenSurreal

/// Identifier shared between the `ImmersiveSpace` scene and the open/dismiss actions.
let immersiveSpaceID = "ControllerSpace"

/// A minimal showcase of OpenSurreal's API: one `SurrealControllerSession` drives
/// both the library's built-in management UI and the immersive rendering, and we
/// never touch a controller object directly.
@main
struct OpenSurrealExampleApp: App {
    @State private var session = SurrealControllerSession()

    var body: some Scene {
        WindowGroup {
            ContentView(session: session)
                .frame(minWidth: 420, minHeight: 600)
        }
        .windowResizability(.contentSize)

        ImmersiveSpace(id: immersiveSpaceID) {
            ImmersiveControllerView(session: session)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
