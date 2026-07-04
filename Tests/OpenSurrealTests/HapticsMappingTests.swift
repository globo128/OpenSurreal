import XCTest
@testable import OpenSurreal

final class HapticsMappingTests: XCTestCase {

    func testAmplitudeIsClampedAndScaled() {
        XCTAssertEqual(SurrealControllerSession.deviceHapticsParameters(
            amplitude: -1, frequency: 100, duration: 0.2).amplitude, 0)
        XCTAssertEqual(SurrealControllerSession.deviceHapticsParameters(
            amplitude: 0.5, frequency: 100, duration: 0.2).amplitude, 5000)
        XCTAssertEqual(SurrealControllerSession.deviceHapticsParameters(
            amplitude: 2, frequency: 100, duration: 0.2).amplitude, 10000)
    }

    func testFrequencyIsClampedToDeviceRange() {
        XCTAssertEqual(SurrealControllerSession.deviceHapticsParameters(
            amplitude: 0.5, frequency: 0, duration: 0.2).frequency, 20)
        XCTAssertEqual(SurrealControllerSession.deviceHapticsParameters(
            amplitude: 0.5, frequency: 100, duration: 0.2).frequency, 100)
        XCTAssertEqual(SurrealControllerSession.deviceHapticsParameters(
            amplitude: 0.5, frequency: 500, duration: 0.2).frequency, 300)
    }

    func testDurationIsRaisedToDeviceMinimum() {
        XCTAssertEqual(SurrealControllerSession.deviceHapticsParameters(
            amplitude: 0.5, frequency: 100, duration: 0).duration, .milliseconds(30))
        XCTAssertEqual(SurrealControllerSession.deviceHapticsParameters(
            amplitude: 0.5, frequency: 100, duration: 0.2).duration, .milliseconds(200))
    }

    func testNonFiniteInputsFallBackToDefaults() {
        let parameters = SurrealControllerSession.deviceHapticsParameters(
            amplitude: .nan, frequency: .infinity, duration: .nan)
        XCTAssertEqual(parameters.amplitude, 5000)
        XCTAssertEqual(parameters.frequency, 100)
        XCTAssertEqual(parameters.duration, .milliseconds(200))
    }
}
