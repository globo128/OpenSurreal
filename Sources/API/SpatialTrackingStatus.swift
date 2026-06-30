#if os(visionOS)
/// The state of the headset hand-tracking that aligns controllers into world space.
///
/// Returned from ``SurrealControllerSession/startSpatialTracking()`` and observable
/// live at ``SurrealControllerSession/spatialTrackingStatus``. Only `.running`
/// produces ``SurrealControllerSession/worldPoseUpdates``; the other cases tell you
/// why world poses aren't flowing (e.g. authorization was denied).
public enum SpatialTrackingStatus: Sendable, Equatable {
    /// Spatial tracking hasn't been started yet, or has been stopped.
    case notStarted
    /// Hand tracking is running; world poses flow once controllers calibrate.
    case running
    /// This device doesn't support hand tracking.
    case unsupported
    /// The app isn't authorized for hand tracking (check `NSHandsTrackingUsageDescription`).
    case unauthorized
    /// Starting the ARKit session failed, with a human-readable reason.
    case failed(String)

    init(_ status: SurrealSpatialSession.Status) {
        switch status {
        case .idle: self = .notStarted
        case .running: self = .running
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .failed(let message): self = .failed(message)
        }
    }
}
#endif
