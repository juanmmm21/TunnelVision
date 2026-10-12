import XCTest
import Shared

/// Tests de los contadores del nombre de QUIC: lo que se suma, y que viajan enteros.
final class QUICNameStatsTests: XCTestCase {

    func testStartsAtZero() {
        let stats = QUICNameStats()
        XCTAssertEqual(stats.initialsOpened, 0)
        XCTAssertEqual(stats.flowsNamed, 0)
        XCTAssertEqual(stats.flowsLeftUnnamed, 0)
    }

    /// Los flujos que se quedaron sin nombre son la suma de sus cuatro motivos, y nada más: ni
    /// los nombrados ni lo que cuenta paquetes entran en ella.
    func testFlowsLeftUnnamedAddsTheFourReasonsAndNothingElse() {
        let reasons: [WritableKeyPath<QUICNameStats, UInt64>] = [
            \.withoutServerName, \.unreadableClientHello, \.cryptoStreamAbandoned, \.initialsExhausted,
        ]
        for (index, reason) in reasons.enumerated() {
            var stats = QUICNameStats()
            stats[keyPath: reason] = UInt64(index + 3)
            XCTAssertEqual(stats.flowsLeftUnnamed, UInt64(index + 3))
        }

        var stats = QUICNameStats()
        stats.withoutServerName = 1
        stats.unreadableClientHello = 2
        stats.cryptoStreamAbandoned = 4
        stats.initialsExhausted = 8
        stats.flowsNamed = 100
        stats.initialsOpened = 200
        stats.initialsNotOpened = 300
        stats.readsRestarted = 400
        stats.initialsSkippedAtCapacity = 500
        XCTAssertEqual(stats.flowsLeftUnnamed, 15)
    }

    func testSurvivesCodingWithEveryCounterSet() throws {
        var stats = QUICNameStats()
        stats.initialsOpened = 1
        stats.initialsNotOpened = 2
        stats.readsRestarted = 3
        stats.initialsSkippedAtCapacity = 4
        stats.flowsNamed = 5
        stats.withoutServerName = 6
        stats.unreadableClientHello = 7
        stats.cryptoStreamAbandoned = 8
        stats.initialsExhausted = 9

        let decoded = try JSONDecoder().decode(QUICNameStats.self, from: try JSONEncoder().encode(stats))
        XCTAssertEqual(decoded, stats)
    }
}
