import Foundation
import Testing
@testable import RouteBarDomain

@Suite struct LatencyMeasurementTests {
    @Test func prefersRequestToResponseTimingOverColdConnectionDuration() {
        let requestStart = Date(timeIntervalSinceReferenceDate: 1_000)
        let responseStart = requestStart.addingTimeInterval(0.385)

        let milliseconds = LatencyMeasurement.milliseconds(
            requestStart: requestStart,
            responseStart: responseStart,
            fallback: .milliseconds(1_480)
        )

        #expect(milliseconds == 385)
    }

    @Test func fallsBackWhenTaskMetricsAreUnavailableOrInvalid() {
        let fallback = Duration.milliseconds(1_480)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(LatencyMeasurement.milliseconds(
            requestStart: nil,
            responseStart: nil,
            fallback: fallback
        ) == 1_480)
        #expect(LatencyMeasurement.milliseconds(
            requestStart: start,
            responseStart: start.addingTimeInterval(-1),
            fallback: fallback
        ) == 1_480)
    }
}
