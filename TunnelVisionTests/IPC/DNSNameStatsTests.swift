import XCTest
import Shared

/// Tests de los contadores del mapa de nombres. Cada desenlace tiene que caer en su casilla y solo
/// en ella: son lo que permite decir por qué una sesión se quedó sin nombres.
final class DNSNameStatsTests: XCTestCase {

    func testNothingIsCountedBeforeAnythingIsSeen() {
        let stats = DNSNameStats()

        XCTAssertEqual(stats.repliesRecorded, 0)
        XCTAssertEqual(stats.repliesIgnored, 0)
        XCTAssertEqual(stats.unreadable, 0)
        XCTAssertEqual(stats.flowsNamed, 0)
    }

    func testARecordedReplyCountsItselfAndItsAddresses() {
        var stats = DNSNameStats()

        stats.count(.recorded(addresses: 2))
        stats.count(.recorded(addresses: 1))

        XCTAssertEqual(stats.repliesRecorded, 2)
        XCTAssertEqual(stats.addressesRecorded, 3)
        XCTAssertEqual(stats.repliesIgnored, 0)
    }

    func testEachReasonForRecordingNothingHasItsOwnCounter() {
        let reasons: [(DNSNameIngestion.Reason, KeyPath<DNSNameStats, UInt64>)] = [
            (.notAResponse, \.notAResponse),
            (.unsupportedOpcode, \.unsupportedOpcode),
            (.errorResponse, \.errorResponses),
            (.unsupportedQuestion, \.unsupportedQuestions),
            (.unusableName, \.unusableNames),
            (.noAddresses, \.withoutAddresses),
        ]

        for (reason, counter) in reasons {
            var stats = DNSNameStats()
            stats.count(.ignored(reason))

            XCTAssertEqual(stats[keyPath: counter], 1, "\(reason)")
            XCTAssertEqual(stats.repliesIgnored, 1, "\(reason) solo cuenta en su casilla")
            XCTAssertEqual(stats.repliesRecorded, 0, "\(reason)")
            XCTAssertEqual(stats.addressesRecorded, 0, "\(reason)")
        }
    }

    func testTheIgnoredTotalAddsEveryReason() {
        var stats = DNSNameStats()
        stats.count(.ignored(.notAResponse))
        stats.count(.ignored(.errorResponse))
        stats.count(.ignored(.errorResponse))
        stats.count(.ignored(.noAddresses))
        stats.count(.recorded(addresses: 4))

        XCTAssertEqual(stats.repliesIgnored, 4)
    }
}
