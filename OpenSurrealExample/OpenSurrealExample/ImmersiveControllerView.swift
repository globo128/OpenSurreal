import SwiftUI
import RealityKit
import UIKit
import OpenSurreal

/// Draws a sphere per connected controller in world space, driven entirely by the
/// session's aggregated streams — `worldPoseUpdates` positions each sphere and
/// `buttonUpdates` scales it with the trigger. No controller objects are handled
/// directly; every event already says which hand it came from.
struct ImmersiveControllerView: View {
    let session: SurrealControllerSession

    @State private var scene = ControllerScene()

    var body: some View {
        RealityView { content in
            content.add(scene.root)
            // Hand tracking needs to run inside an immersive space; calibrated
            // world poses start flowing on `worldPoseUpdates` once it's up.
            await session.startSpatialTracking()
        }
        .task {
            for await update in session.worldPoseUpdates { scene.place(update) }
        }
        .task {
            for await update in session.buttonUpdates { scene.react(to: update) }
        }
        .onDisappear { session.stopSpatialTracking() }
    }
}

/// Owns the world-space root and one sphere entity per hand, created on demand.
@MainActor
private final class ControllerScene {
    let root = Entity()
    private var entities: [Handedness: Entity] = [:]

    /// Positions the controller's sphere from its world pose.
    func place(_ pose: WorldPose) {
        entity(for: pose.handedness).transform = Transform(matrix: pose.transform)
    }

    /// Grows the sphere with the trigger (normalized `0...1`). Only acts on a sphere a
    /// world pose has already placed, so a button press never spawns an unpositioned
    /// one at the origin.
    func react(to update: ButtonUpdate) {
        guard let entity = entities[update.handedness] else { return }
        entity.scale = SIMD3(repeating: 1 + update.trigger)
    }

    private func entity(for hand: Handedness) -> Entity {
        if let existing = entities[hand] { return existing }
        let entity = ControllerScene.makeEntity(for: hand)
        entities[hand] = entity
        root.addChild(entity)
        return entity
    }

    /// A colored sphere with a white "forward" (−Z) stick so orientation reads.
    private static func makeEntity(for hand: Handedness) -> Entity {
        let color: UIColor = switch hand {
        case .left: .systemBlue
        case .right: .systemGreen
        case .unspecified: .systemGray
        }
        let entity = Entity()
        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.03),
            materials: [SimpleMaterial(color: color, isMetallic: false)]
        )
        entity.addChild(sphere)
        let stick = ModelEntity(
            mesh: .generateBox(width: 0.008, height: 0.008, depth: 0.12, cornerRadius: 0.004),
            materials: [SimpleMaterial(color: .white, isMetallic: false)]
        )
        stick.position = [0, 0, -0.06]
        entity.addChild(stick)
        return entity
    }
}
