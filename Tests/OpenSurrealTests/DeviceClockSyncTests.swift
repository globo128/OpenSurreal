import XCTest
@testable import OpenSurreal

final class DeviceClockSyncTests: XCTestCase {

    /// Device clock: ticks are nanoseconds. Packets every 10 ms.
    private let tickPeriod: UInt64 = 10_000_000
    private let packetPeriod = 0.01

    /// The min-filter should converge on the fastest delivery path: with a known
    /// true offset and varying delivery delays, the estimated sample time should
    /// equal true measurement time + the smallest delay seen in the window.
    func testConvergesToFastestDeliveryPath() {
        var sync = DeviceClockSync()
        let trueOffset = 1000.0 // host = device seconds + offset
        // Deterministic delay pattern, minimum 2 ms.
        let delays = [0.015, 0.008, 0.002, 0.020, 0.011, 0.005, 0.017, 0.003]

        var lastEstimate = 0.0
        var lastMeasured = 0.0
        for i in 0..<100 {
            let deviceTicks = UInt64(i) * tickPeriod
            let measuredAt = Double(deviceTicks) * 1e-9 + trueOffset
            let receivedAt = measuredAt + delays[i % delays.count]
            lastEstimate = sync.sampleTime(deviceTimestamp: deviceTicks, receivedAt: receivedAt)
            lastMeasured = measuredAt
        }
        // Estimate = measured + min(delay) once the window has seen the fast path.
        XCTAssertEqual(lastEstimate, lastMeasured + 0.002, accuracy: 1e-6)
    }

    /// The estimate must always be usable as a host timestamp: never in the future,
    /// never older than the credibility bound.
    func testEstimateIsRecentPast() {
        var sync = DeviceClockSync()
        for i in 0..<50 {
            let deviceTicks = UInt64(i) * tickPeriod
            let receivedAt = Double(i) * packetPeriod + 500.0
            let estimate = sync.sampleTime(deviceTimestamp: deviceTicks, receivedAt: receivedAt)
            XCTAssertLessThanOrEqual(estimate, receivedAt)
            XCTAssertLessThan(receivedAt - estimate, DeviceClockSync.maxCredibleAge)
        }
    }

    /// A controller reboot resets its tick counter, making the offset jump by far
    /// more than the reset threshold — the estimator must discard the stale window
    /// instead of clamping to it.
    func testRebootResetsEstimator() {
        var sync = DeviceClockSync()
        var receivedAt = 2000.0
        for i in 0..<50 {
            _ = sync.sampleTime(deviceTimestamp: UInt64(1_000_000_000_000) + UInt64(i) * tickPeriod,
                                receivedAt: receivedAt)
            receivedAt += packetPeriod
        }
        // Reboot: ticks restart near zero. First post-reboot estimate must still be
        // credible (falls back to the new sample's own offset).
        let estimate = sync.sampleTime(deviceTimestamp: tickPeriod, receivedAt: receivedAt)
        XCTAssertEqual(estimate, receivedAt, accuracy: 1e-9)
        // And subsequent packets keep working on the new timeline.
        let next = sync.sampleTime(deviceTimestamp: 2 * tickPeriod, receivedAt: receivedAt + packetPeriod)
        XCTAssertLessThanOrEqual(next, receivedAt + packetPeriod)
        XCTAssertLessThan((receivedAt + packetPeriod) - next, DeviceClockSync.maxCredibleAge)
    }

    /// If a firmware revision changed the tick unit (device seconds advancing at the
    /// wrong rate), the min-filter's estimate drifts stale — the guard must fall back
    /// to arrival time rather than emit ancient sample times.
    func testWrongTickUnitFallsBackToArrivalTime() {
        var sync = DeviceClockSync()
        var fellBack = false
        for i in 0..<100 {
            // Ticks advance as if microseconds (1000x slower than the assumed ns).
            let deviceTicks = UInt64(i) * 10_000
            let receivedAt = Double(i) * packetPeriod + 300.0
            let estimate = sync.sampleTime(deviceTimestamp: deviceTicks, receivedAt: receivedAt)
            XCTAssertLessThan(receivedAt - estimate, DeviceClockSync.maxCredibleAge)
            if estimate == receivedAt && i > 0 { fellBack = true }
        }
        XCTAssertTrue(fellBack, "estimator should have detected the stale estimate and fallen back")
    }
}
