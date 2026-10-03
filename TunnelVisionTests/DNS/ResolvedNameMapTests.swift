import Foundation
import XCTest
import Shared

/// Tests del mapa dirección → nombre: **qué entra, cuándo caduca, cuánto ocupa y cómo se desempata**.
///
/// Los mensajes se construyen como valores `DNSMessage` y no como bytes: el mapa no lee la red, lee
/// lo que el disector ya leyó, y así cada caso dice exactamente qué registros trae —incluidos los que
/// `DNSMessageFixture` no sabe escribir, como un registro cuyo dueño no es la pregunta—. Un único
/// caso al final recorre el camino entero desde los bytes.
final class ResolvedNameMapTests: XCTestCase {

    // MARK: - Utilidades

    private let roomy = ResolvedNameLimits(
        capacity: 64, namesPerAddress: 4, minimumLifetime: 0, maximumLifetime: 86_400
    )

    private func seconds(_ count: UInt64) -> UInt64 { count * 1_000_000_000 }

    private func address(_ text: String) throws -> IPAddress {
        try XCTUnwrap(IPAddress(parsing: text))
    }

    private func a(_ owner: String, _ ip: String, ttl: UInt32 = 300, recordClass: UInt16 = 1) throws -> DNSResourceRecord {
        let parsed = try address(ip)
        return DNSResourceRecord(
            name: owner, type: parsed.version == .v4 ? .a : .aaaa, recordClass: recordClass,
            timeToLive: ttl, data: .address(parsed)
        )
    }

    private func cname(_ owner: String, _ target: String, ttl: UInt32 = 300) -> DNSResourceRecord {
        DNSResourceRecord(name: owner, type: .cname, recordClass: 1, timeToLive: ttl, data: .name(target))
    }

    private func reply(
        to names: [String],
        answers: [DNSResourceRecord],
        isResponse: Bool = true,
        opcode: UInt8 = 0,
        responseCode: DNSResponseCode = .noError,
        questionClass: UInt16 = 1
    ) -> DNSMessage {
        DNSMessage(
            id: 0x4a21, isResponse: isResponse, opcode: opcode, isAuthoritative: false,
            isTruncated: false, recursionDesired: true, recursionAvailable: true,
            responseCode: responseCode,
            questions: names.map { DNSQuestion(name: $0, type: .a, recordClass: questionClass) },
            answers: answers
        )
    }

    private func reply(to name: String, _ answers: DNSResourceRecord...) -> DNSMessage {
        reply(to: [name], answers: answers)
    }

    // MARK: - Qué entra

    func testAnAddressAnswerNamesItsAddress() throws {
        var map = ResolvedNameMap(limits: roomy)

        let outcome = map.ingest(
            reply(
                to: "api.example.com",
                try a("api.example.com", "203.0.113.10"),
                try a("api.example.com", "2001:db8::7")
            ),
            at: seconds(100)
        )

        XCTAssertEqual(outcome, .recorded(addresses: 2))
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(
            map.name(for: try address("203.0.113.10"), at: seconds(101)),
            ResolvedName(name: "api.example.com", resolvedAt: seconds(100), otherNames: [])
        )
        XCTAssertEqual(map.name(for: try address("2001:db8::7"), at: seconds(101))?.name, "api.example.com")
        XCTAssertNil(map.name(for: try address("203.0.113.11"), at: seconds(101)), "una dirección que nadie contestó")
    }

    func testTheNameIsTheOneAskedForNotTheEndOfTheAliasChain() throws {
        var map = ResolvedNameMap(limits: roomy)

        map.ingest(
            reply(
                to: "api.example.com",
                cname("api.example.com", "edge.cdn.example.net"),
                cname("edge.cdn.example.net", "pop7.cdn.example.net"),
                try a("pop7.cdn.example.net", "203.0.113.10")
            ),
            at: seconds(1)
        )

        XCTAssertEqual(
            map.name(for: try address("203.0.113.10"), at: seconds(2))?.name, "api.example.com",
            "lo que la allowlist autoriza es lo que la app pidió, no dónde lo aloja su CDN"
        )
    }

    func testAnAliasChainIsFollowedWhateverTheOrderOfTheRecords() throws {
        var map = ResolvedNameMap(limits: roomy)

        let outcome = map.ingest(
            reply(
                to: "api.example.com",
                try a("pop7.cdn.example.net", "203.0.113.10"),
                cname("edge.cdn.example.net", "pop7.cdn.example.net"),
                cname("api.example.com", "edge.cdn.example.net")
            ),
            at: seconds(1)
        )

        XCTAssertEqual(outcome, .recorded(addresses: 1))
    }

    func testAnAddressThatDoesNotAnswerTheQuestionIsNotRecorded() throws {
        var map = ResolvedNameMap(limits: roomy)

        let outcome = map.ingest(
            reply(
                to: "api.example.com",
                try a("api.example.com", "203.0.113.10"),
                try a("bank.example.org", "198.51.100.5"),
                cname("other.example.org", "elsewhere.example.org"),
                try a("elsewhere.example.org", "198.51.100.6")
            ),
            at: seconds(1)
        )

        XCTAssertEqual(outcome, .recorded(addresses: 1))
        XCTAssertNil(map.name(for: try address("198.51.100.5"), at: seconds(2)))
        XCTAssertNil(map.name(for: try address("198.51.100.6"), at: seconds(2)), "un CNAME que no cuelga de la pregunta")
    }

    func testAnAliasLoopEnds() throws {
        var map = ResolvedNameMap(limits: roomy)

        let outcome = map.ingest(
            reply(
                to: "a.example.com",
                cname("a.example.com", "b.example.com"),
                cname("b.example.com", "a.example.com"),
                try a("b.example.com", "203.0.113.10")
            ),
            at: seconds(1)
        )

        XCTAssertEqual(outcome, .recorded(addresses: 1))
        XCTAssertEqual(map.name(for: try address("203.0.113.10"), at: seconds(2))?.name, "a.example.com")
    }

    func testNamesAreComparedAndStoredWithoutCase() throws {
        var map = ResolvedNameMap(limits: roomy)

        // La aleatorización 0x20: la pregunta vuelve con las mayúsculas que el resolutor quiso.
        map.ingest(
            reply(
                to: "ApI.ExAmPlE.CoM",
                cname("api.example.com", "Edge.Example.NET"),
                try a("edge.example.net", "203.0.113.10")
            ),
            at: seconds(1)
        )

        XCTAssertEqual(map.name(for: try address("203.0.113.10"), at: seconds(2))?.name, "api.example.com")
    }

    func testAMessageThatAnswersNothingIsIgnoredWithItsReason() throws {
        var map = ResolvedNameMap(limits: roomy)
        let answer = try a("api.example.com", "203.0.113.10")
        let ignored: [(DNSMessage, DNSNameIngestion.Reason)] = [
            (reply(to: ["api.example.com"], answers: [answer], isResponse: false), .notAResponse),
            (reply(to: ["api.example.com"], answers: [answer], opcode: 5), .unsupportedOpcode),
            (reply(to: ["api.example.com"], answers: [answer], responseCode: .nonExistentDomain), .errorResponse),
            (reply(to: [], answers: [answer]), .unsupportedQuestion),
            (reply(to: ["api.example.com", "b.example.com"], answers: [answer]), .unsupportedQuestion),
            (reply(to: ["api.example.com"], answers: [answer], questionClass: 3), .unsupportedQuestion),
            (reply(to: ["api.example.com"], answers: []), .noAddresses),
            (reply(to: "api.example.com", cname("api.example.com", "edge.example.net")), .noAddresses),
        ]

        for (message, reason) in ignored {
            XCTAssertEqual(map.ingest(message, at: seconds(1)), .ignored(reason))
        }
        XCTAssertEqual(map.count, 0)
    }

    func testANameThatIsNotAHostnameIsNotStored() throws {
        var map = ResolvedNameMap(limits: roomy)

        // La raíz, un byte escapado por el parser y el comodín literal: ninguno podría escribirse como
        // una entrada exacta de la allowlist, así que ninguno serviría para compararse con ella.
        for name in [".", "a\\032b.example.com", "*.example.com"] {
            XCTAssertEqual(
                map.ingest(reply(to: name, try a(name, "203.0.113.10")), at: seconds(1)),
                .ignored(.unusableName),
                name
            )
        }
        XCTAssertEqual(map.count, 0)
    }

    func testARecordThatIsNotAnInternetAddressIsSkipped() throws {
        var map = ResolvedNameMap(limits: roomy)
        let malformed = DNSResourceRecord(
            name: "api.example.com", type: .a, recordClass: 1, timeToLive: 300, data: .opaque(byteCount: 3)
        )

        let outcome = map.ingest(
            reply(to: "api.example.com", malformed, try a("api.example.com", "203.0.113.10", recordClass: 3)),
            at: seconds(1)
        )

        XCTAssertEqual(outcome, .ignored(.noAddresses))
    }

    // MARK: - Cuándo caduca

    func testANameLivesUntilItsTimeToLiveRunsOut() throws {
        var map = ResolvedNameMap(limits: roomy)
        let ip = try address("203.0.113.10")

        map.ingest(reply(to: "api.example.com", try a("api.example.com", "203.0.113.10", ttl: 30)), at: seconds(100))

        XCTAssertNotNil(map.name(for: ip, at: seconds(100)))
        XCTAssertNotNil(map.name(for: ip, at: seconds(130) - 1))
        XCTAssertNil(map.name(for: ip, at: seconds(130)), "el instante en que caduca ya no vale")
    }

    func testAnAliasedAddressLivesAsLongAsTheShortestLinkOfItsChain() throws {
        var map = ResolvedNameMap(limits: roomy)
        let ip = try address("203.0.113.10")

        map.ingest(
            reply(
                to: "api.example.com",
                cname("api.example.com", "edge.example.net", ttl: 3600),
                cname("edge.example.net", "pop7.example.net", ttl: 20),
                try a("pop7.example.net", "203.0.113.10", ttl: 300)
            ),
            at: seconds(0)
        )

        XCTAssertNotNil(map.name(for: ip, at: seconds(19)))
        XCTAssertNil(map.name(for: ip, at: seconds(20)))
    }

    func testAnAddressAnsweredTwiceLivesAsLongAsItsShorterAnswer() throws {
        var map = ResolvedNameMap(limits: roomy)
        let ip = try address("203.0.113.10")

        let outcome = map.ingest(
            reply(
                to: "api.example.com",
                try a("api.example.com", "203.0.113.10", ttl: 300),
                try a("api.example.com", "203.0.113.10", ttl: 10)
            ),
            at: seconds(0)
        )

        XCTAssertEqual(outcome, .recorded(addresses: 1))
        XCTAssertEqual(map.count, 1)
        XCTAssertNil(map.name(for: ip, at: seconds(10)))
    }

    func testTheLimitsBoundHowLongAnAnswerIsBelieved() throws {
        var map = ResolvedNameMap(
            limits: ResolvedNameLimits(capacity: 8, namesPerAddress: 2, minimumLifetime: 60, maximumLifetime: 3600)
        )
        let brief = try address("203.0.113.10")
        let eternal = try address("203.0.113.11")

        map.ingest(reply(to: "brief.example.com", try a("brief.example.com", "203.0.113.10", ttl: 0)), at: seconds(0))
        map.ingest(
            reply(to: "eternal.example.com", try a("eternal.example.com", "203.0.113.11", ttl: .max)),
            at: seconds(0)
        )

        XCTAssertNotNil(map.name(for: brief, at: seconds(59)), "un TTL de cero no deja sin nombre a la conexión que viene detrás")
        XCTAssertNil(map.name(for: brief, at: seconds(60)))
        XCTAssertNotNil(map.name(for: eternal, at: seconds(3599)))
        XCTAssertNil(map.name(for: eternal, at: seconds(3600)), "un TTL de 136 años no se cree")
    }

    func testSeeingTheAnswerAgainRenewsIt() throws {
        var map = ResolvedNameMap(limits: roomy)
        let ip = try address("203.0.113.10")
        let message = reply(to: "api.example.com", try a("api.example.com", "203.0.113.10", ttl: 30))

        map.ingest(message, at: seconds(0))
        map.ingest(message, at: seconds(25))

        XCTAssertEqual(map.count, 1, "el mismo par no se guarda dos veces")
        XCTAssertEqual(map.name(for: ip, at: seconds(40))?.resolvedAt, seconds(25))
        XCTAssertNil(map.name(for: ip, at: seconds(55)))
    }

    func testAnExpiryPastTheEndOfTheClockDoesNotWrapAround() throws {
        var map = ResolvedNameMap(limits: roomy)
        let ip = try address("203.0.113.10")

        map.ingest(reply(to: "api.example.com", try a("api.example.com", "203.0.113.10", ttl: 300)), at: .max - 5)

        XCTAssertNotNil(map.name(for: ip, at: .max - 1), "sin saturar, la caducidad daría la vuelta y ya estaría caducado")
    }

    func testRemovingTheExpiredOnesReturnsTheirRoom() throws {
        var map = ResolvedNameMap(limits: roomy)
        map.ingest(reply(to: "short.example.com", try a("short.example.com", "203.0.113.10", ttl: 10)), at: seconds(0))
        map.ingest(reply(to: "long.example.com", try a("long.example.com", "203.0.113.10", ttl: 600)), at: seconds(0))
        map.ingest(reply(to: "gone.example.com", try a("gone.example.com", "203.0.113.11", ttl: 10)), at: seconds(0))

        XCTAssertEqual(map.removeExpired(at: seconds(5)), 0)
        XCTAssertEqual(map.removeExpired(at: seconds(10)), 2)
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map.name(for: try address("203.0.113.10"), at: seconds(11))?.name, "long.example.com")
    }

    // MARK: - Cómo se desempata

    func testOnASharedAddressTheMostRecentlyResolvedNameWinsAndTheOthersAreTold() throws {
        var map = ResolvedNameMap(limits: roomy)
        let ip = try address("203.0.113.10")

        map.ingest(reply(to: "first.example.com", try a("first.example.com", "203.0.113.10")), at: seconds(1))
        map.ingest(reply(to: "second.example.org", try a("second.example.org", "203.0.113.10")), at: seconds(2))
        map.ingest(reply(to: "third.example.net", try a("third.example.net", "203.0.113.10")), at: seconds(3))

        XCTAssertEqual(
            map.name(for: ip, at: seconds(4)),
            ResolvedName(
                name: "third.example.net", resolvedAt: seconds(3),
                otherNames: ["second.example.org", "first.example.com"]
            )
        )
    }

    func testResolvingAnOlderNameAgainPutsItFirst() throws {
        var map = ResolvedNameMap(limits: roomy)
        let ip = try address("203.0.113.10")

        map.ingest(reply(to: "first.example.com", try a("first.example.com", "203.0.113.10")), at: seconds(1))
        map.ingest(reply(to: "second.example.org", try a("second.example.org", "203.0.113.10")), at: seconds(2))
        map.ingest(reply(to: "first.example.com", try a("first.example.com", "203.0.113.10")), at: seconds(3))

        let resolved = map.name(for: ip, at: seconds(4))
        XCTAssertEqual(resolved?.name, "first.example.com")
        XCTAssertEqual(resolved?.otherNames, ["second.example.org"])
    }

    func testAnExpiredWinnerGivesWayToAnOlderNameThatIsStillAlive() throws {
        var map = ResolvedNameMap(limits: roomy)
        let ip = try address("203.0.113.10")

        map.ingest(reply(to: "lasting.example.com", try a("lasting.example.com", "203.0.113.10", ttl: 600)), at: seconds(1))
        map.ingest(reply(to: "fleeting.example.org", try a("fleeting.example.org", "203.0.113.10", ttl: 10)), at: seconds(2))

        XCTAssertEqual(map.name(for: ip, at: seconds(5))?.name, "fleeting.example.org")
        XCTAssertEqual(
            map.name(for: ip, at: seconds(12)),
            ResolvedName(name: "lasting.example.com", resolvedAt: seconds(1), otherNames: []),
            "un nombre caducado ni gana ni se cuenta entre los otros"
        )
    }

    func testNamesResolvedAtTheSameInstantAreOrderedByName() throws {
        let ip = try address("203.0.113.10")
        let messages = [
            reply(to: "zeta.example.com", try a("zeta.example.com", "203.0.113.10")),
            reply(to: "alpha.example.com", try a("alpha.example.com", "203.0.113.10")),
        ]

        // En los dos órdenes de llegada: la respuesta no puede depender de cuál se apuntó antes.
        for order in [messages, messages.reversed()] {
            var map = ResolvedNameMap(limits: roomy)
            for message in order { map.ingest(message, at: seconds(1)) }

            XCTAssertEqual(
                map.name(for: ip, at: seconds(2)),
                ResolvedName(name: "alpha.example.com", resolvedAt: seconds(1), otherNames: ["zeta.example.com"])
            )
        }
    }

    func testAnAddressRemembersOnlySoManyNamesAndForgetsTheOldest() throws {
        var map = ResolvedNameMap(
            limits: ResolvedNameLimits(capacity: 64, namesPerAddress: 2, minimumLifetime: 0, maximumLifetime: 86_400)
        )
        let ip = try address("203.0.113.10")

        for (index, name) in ["one.example.com", "two.example.com", "three.example.com"].enumerated() {
            map.ingest(reply(to: name, try a(name, "203.0.113.10")), at: seconds(UInt64(index + 1)))
        }

        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map.name(for: ip, at: seconds(4))?.name, "three.example.com")
        XCTAssertEqual(map.name(for: ip, at: seconds(4))?.otherNames, ["two.example.com"])
    }

    // MARK: - Cuánto ocupa

    func testAFullMapMakesRoomWithWhatHasExpiredFirst() throws {
        var map = ResolvedNameMap(
            limits: ResolvedNameLimits(capacity: 2, namesPerAddress: 2, minimumLifetime: 0, maximumLifetime: 86_400)
        )
        // El más antiguo sigue vivo y el más reciente ha caducado: se va el caducado.
        map.ingest(reply(to: "old.example.com", try a("old.example.com", "203.0.113.1", ttl: 600)), at: seconds(1))
        map.ingest(reply(to: "expired.example.com", try a("expired.example.com", "203.0.113.2", ttl: 5)), at: seconds(2))

        map.ingest(reply(to: "new.example.com", try a("new.example.com", "203.0.113.3", ttl: 600)), at: seconds(10))

        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map.name(for: try address("203.0.113.1"), at: seconds(11))?.name, "old.example.com")
        XCTAssertEqual(map.name(for: try address("203.0.113.3"), at: seconds(11))?.name, "new.example.com")
    }

    func testAFullMapWithNothingExpiredForgetsTheLeastRecentlyResolved() throws {
        var map = ResolvedNameMap(
            limits: ResolvedNameLimits(capacity: 3, namesPerAddress: 2, minimumLifetime: 0, maximumLifetime: 86_400)
        )
        map.ingest(reply(to: "one.example.com", try a("one.example.com", "203.0.113.1")), at: seconds(1))
        map.ingest(reply(to: "two.example.com", try a("two.example.com", "203.0.113.2")), at: seconds(2))
        map.ingest(reply(to: "three.example.com", try a("three.example.com", "203.0.113.3")), at: seconds(3))
        // Volver a resolver el primero lo saca del final de la cola.
        map.ingest(reply(to: "one.example.com", try a("one.example.com", "203.0.113.1")), at: seconds(4))

        map.ingest(reply(to: "four.example.com", try a("four.example.com", "203.0.113.4")), at: seconds(5))

        XCTAssertEqual(map.count, 3)
        XCTAssertNil(map.name(for: try address("203.0.113.2"), at: seconds(6)), "era el que hacía más que se resolvió")
        XCTAssertNotNil(map.name(for: try address("203.0.113.1"), at: seconds(6)))
        XCTAssertNotNil(map.name(for: try address("203.0.113.3"), at: seconds(6)))
        XCTAssertNotNil(map.name(for: try address("203.0.113.4"), at: seconds(6)))
    }

    func testRenewingAPairInAFullMapForgetsNothing() throws {
        var map = ResolvedNameMap(
            limits: ResolvedNameLimits(capacity: 2, namesPerAddress: 2, minimumLifetime: 0, maximumLifetime: 86_400)
        )
        map.ingest(reply(to: "one.example.com", try a("one.example.com", "203.0.113.1")), at: seconds(1))
        map.ingest(reply(to: "two.example.com", try a("two.example.com", "203.0.113.2")), at: seconds(2))

        map.ingest(reply(to: "two.example.com", try a("two.example.com", "203.0.113.2")), at: seconds(3))

        XCTAssertEqual(map.count, 2)
        XCTAssertNotNil(map.name(for: try address("203.0.113.1"), at: seconds(4)))
    }

    func testTheMapNeverHoldsMoreThanItsCapacity() throws {
        var map = ResolvedNameMap(
            limits: ResolvedNameLimits(capacity: 16, namesPerAddress: 3, minimumLifetime: 0, maximumLifetime: 86_400)
        )

        // Una respuesta con más direcciones que capacidad, y luego muchos nombres sobre pocas direcciones.
        let flood = try (0..<40).map { try a("flood.example.com", "198.51.100.\($0)") }
        map.ingest(reply(to: ["flood.example.com"], answers: flood), at: seconds(1))
        XCTAssertEqual(map.count, 16)

        for index in 0..<200 {
            let name = "host\(index).example.com"
            map.ingest(reply(to: name, try a(name, "203.0.113.\(index % 5)")), at: seconds(UInt64(2 + index)))
            XCTAssertLessThanOrEqual(map.count, 16)
        }
        XCTAssertEqual(map.name(for: try address("203.0.113.4"), at: seconds(300))?.name, "host199.example.com")
    }

    func testWhatAFullMapForgetsDoesNotDependOnDictionaryOrder() throws {
        // Ocho direcciones resueltas en el mismo instante y una novena que obliga a soltar una: con
        // todos los instantes iguales, la que se va tiene que ser siempre la misma.
        let limits = ResolvedNameLimits(capacity: 8, namesPerAddress: 2, minimumLifetime: 0, maximumLifetime: 86_400)
        let flood = try (1...8).map { try a("many.example.com", "203.0.113.\($0)") }

        for _ in 0..<20 {
            var map = ResolvedNameMap(limits: limits)
            map.ingest(reply(to: ["many.example.com"], answers: flood.shuffled()), at: seconds(1))
            map.ingest(reply(to: "late.example.com", try a("late.example.com", "203.0.113.200")), at: seconds(1))

            XCTAssertNil(map.name(for: try address("203.0.113.1"), at: seconds(2)), "se va la menor de las direcciones")
            XCTAssertNotNil(map.name(for: try address("203.0.113.2"), at: seconds(2)))
        }
    }

    // MARK: - De los bytes al nombre

    func testAReplyReadOffTheWireNamesItsAddresses() throws {
        var map = ResolvedNameMap(limits: .tunnel)
        let bytes = DNSMessageFixture.reply(
            id: 0x4a21, name: "api.example.com", type: .a,
            answers: [.address(try address("203.0.113.10")), .address(try address("203.0.113.11"))],
            timeToLive: 120
        )

        let outcome = map.ingest(try DNSMessageParser.parse(bytes), at: seconds(10))

        XCTAssertEqual(outcome, .recorded(addresses: 2))
        XCTAssertEqual(map.name(for: try address("203.0.113.11"), at: seconds(129))?.name, "api.example.com")
        XCTAssertNil(map.name(for: try address("203.0.113.11"), at: seconds(130)))

        // Y la consulta que la precedió no apunta nada.
        let query = try DNSMessageParser.parse(DNSMessageFixture.query(id: 0x4a21, name: "api.example.com", type: .a))
        XCTAssertEqual(map.ingest(query, at: seconds(9)), .ignored(.notAResponse))
    }
}
