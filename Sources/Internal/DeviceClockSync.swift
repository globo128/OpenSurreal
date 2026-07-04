import Foundation

/// Maps firmware pose timestamps onto the host's `CACurrentMediaTime()` clock.
///
/// For each packet, `receivedAt − deviceTime` is the true clock offset plus a
/// non-negative delivery delay (BLE link + radio scheduling), so the minimum of that
/// difference over a sliding window tracks the fastest-delivery path and converges on
/// the true offset. This is the one-way half of an NTP sync — the vendor SDK runs a
/// full 4-timestamp NTP over its control channel, but the min-filter needs no
/// firmware cooperation and gets within one BLE connection interval of it.
///
/// Callers should stamp `receivedAt` as close to the radio as possible (the
/// CoreBluetooth delegate callback) — every scheduling hop between the notification
/// and the stamp adds noise to the offset samples.
struct DeviceClockSync {
    /// Firmware ticks are nanoseconds: the tick rate measures exactly 1 GHz
    /// (~9.85e6 ticks between packets at ~101.5 Hz, confirmed on-device).
    static let tickToSeconds = 1e-9
    /// Min-filter horizon. Crystal drift over 3 s (~50 ppm) is ~0.15 ms — negligible.
    static let windowSeconds = 3.0
    /// An offset jump this large means the device rebooted (timestamps reset).
    static let resetThreshold = 0.5
    /// A sample estimated older than this means the estimator itself is wrong (e.g. a
    /// firmware revision changed the tick unit) — fall back to arrival time.
    static let maxCredibleAge = 0.25

    private var samples: [(receivedAt: TimeInterval, offset: TimeInterval)] = []

    /// The estimated host-clock time the sample with `deviceTimestamp` was measured.
    /// Falls back to `receivedAt` whenever the estimate isn't credible, so the result
    /// is always usable as a host-clock timestamp.
    mutating func sampleTime(deviceTimestamp: UInt64, receivedAt: TimeInterval) -> TimeInterval {
        let deviceTime = Double(deviceTimestamp) * Self.tickToSeconds
        let offset = receivedAt - deviceTime
        if let last = samples.last, abs(offset - last.offset) > Self.resetThreshold {
            samples.removeAll()
        }
        samples.append((receivedAt: receivedAt, offset: offset))
        samples.removeAll { receivedAt - $0.receivedAt > Self.windowSeconds }
        let minOffset = samples.min { $0.offset < $1.offset }!.offset
        let sampleTime = deviceTime + minOffset
        guard receivedAt - sampleTime < Self.maxCredibleAge else {
            return receivedAt
        }
        return sampleTime
    }
}
