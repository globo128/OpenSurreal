import Foundation

extension SurrealControllerSession {
    /// Sends a haptic pulse to the connected controller(s) for the given hand.
    ///
    /// `.unspecified` targets every connected controller. Parameters are clamped to
    /// the device's supported ranges, and the call is fire-and-forget: it's safe to
    /// invoke at high rates — a pulse requested while the device is already
    /// vibrating resolves as a no-op.
    ///
    /// - Parameters:
    ///   - handedness: Which controller to buzz; `.unspecified` buzzes all.
    ///   - amplitude: Normalized strength `0...1` (clamped).
    ///   - frequency: Frequency in Hz, clamped to the device's `20...300`.
    ///   - duration: Duration in seconds, raised to the device minimum of 30 ms.
    public func vibrate(
        _ handedness: Handedness,
        amplitude: Float = 0.5,
        frequency: Float = 100,
        duration: TimeInterval = 0.2
    ) {
        let parameters = Self.deviceHapticsParameters(
            amplitude: amplitude, frequency: frequency, duration: duration
        )
        for connected in connectedControllers
        where handedness == .unspecified || connected.handedness == handedness {
            let controller = connected.controller
            Task {
                try? await controller.vibrate(
                    amplitude: parameters.amplitude,
                    frequency: parameters.frequency,
                    duration: parameters.duration
                )
            }
        }
    }

    /// Maps normalized haptics parameters onto the device's supported ranges.
    nonisolated static func deviceHapticsParameters(
        amplitude: Float,
        frequency: Float,
        duration: TimeInterval
    ) -> (amplitude: UInt16, frequency: UInt16, duration: Duration) {
        let safeAmplitude = amplitude.isFinite ? amplitude : 0.5
        let safeFrequency = frequency.isFinite ? frequency : 100
        let safeDuration = duration.isFinite ? duration : 0.2
        let deviceAmplitude = UInt16((min(max(safeAmplitude, 0), 1) * 10000).rounded())
        let deviceFrequency = UInt16(min(max(safeFrequency, 20), 300).rounded())
        let milliseconds = Int64((min(max(safeDuration, 0.03), 60) * 1000).rounded())
        return (deviceAmplitude, deviceFrequency, .milliseconds(milliseconds))
    }
}
