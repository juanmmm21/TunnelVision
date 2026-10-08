import XCTest
import Shared

/// Tests del nombre de un flujo con su origen. Lo que se afirma es la regla, que es corta y decide
/// qué lee un informe: el SNI gana, el DNS nombra lo que no anuncia nada, y un nombre deducido no se
/// presenta nunca como anunciado.
final class FlowNameTests: XCTestCase {

    private let resolved = ResolvedFlowName(name: "api.example.com", otherNames: ["cdn.example.net"])

    func testAFlowWithNeitherHasNoName() {
        XCTAssertNil(FlowName(sni: nil, resolved: nil))
    }

    func testAnAnnouncedNameComesFromTheSNI() {
        let name = FlowName(sni: "www.example.com", resolved: nil)

        XCTAssertEqual(name, FlowName(text: "www.example.com", origin: .sni, otherCandidates: []))
    }

    /// Lo que no anuncia nada —QUIC, lo que no es TLS— se nombra por el DNS, y lo dice.
    func testAResolvedNameComesFromDNSAndBringsItsOtherCandidates() {
        let name = FlowName(sni: nil, resolved: resolved)

        XCTAssertEqual(
            name,
            FlowName(text: "api.example.com", origin: .dns, otherCandidates: ["cdn.example.net"])
        )
    }

    /// Con los dos, manda lo que la conexión dijo de sí misma, y los candidatos del DNS dejan de
    /// serlo: ya no hay duda de cuál de ellos era.
    func testTheSNIWinsOverAResolvedNameAndDropsItsCandidates() {
        let name = FlowName(sni: "www.example.com", resolved: resolved)

        XCTAssertEqual(name?.text, "www.example.com")
        XCTAssertEqual(name?.origin, .sni)
        XCTAssertEqual(name?.otherCandidates, [])
    }

    /// Un SNI vacío no nombra a nadie: no tapa el nombre resuelto, y solo no es un nombre.
    func testAnEmptySNIDoesNotCount() {
        XCTAssertNil(FlowName(sni: "", resolved: nil))
        XCTAssertEqual(
            FlowName(sni: "", resolved: resolved),
            FlowName(text: "api.example.com", origin: .dns, otherCandidates: ["cdn.example.net"])
        )
    }

    func testAResolvedFlowNameKeepsTheNameAndCandidatesOfTheMapsAnswer() {
        let answer = ResolvedName(name: "api.example.com", resolvedAt: 42, otherNames: ["a.example", "b.example"])

        XCTAssertEqual(
            ResolvedFlowName(answer),
            ResolvedFlowName(name: "api.example.com", otherNames: ["a.example", "b.example"])
        )
    }

    /// Los dos tipos que llevan un flujo dicen lo mismo de su nombre: el del túnel y el del store.
    func testTheRecordAndTheStoredFlowDeriveTheSameName() {
        let key = FlowKey(
            proto: .udp,
            source: ModelFixtures.endpoint(ModelFixtures.v4(10, 0, 0, 2), 51000),
            destination: ModelFixtures.endpoint(ModelFixtures.v4(93, 184, 216, 34), 443)
        )
        let record = FlowRecord(
            id: 0, key: key, firstSeen: 1, lastSeen: 2, bytesOut: 0, bytesIn: 0, packetCount: 1,
            tlsStatus: .plaintext, sni: nil, resolvedName: resolved, serverTLS: nil, serverCertificates: nil, clientTLS: nil, quic: nil, streamOpening: nil
        )
        let stored = StoredFlow(
            id: 1, key: key, firstSeen: Date(timeIntervalSince1970: 1), lastSeen: Date(timeIntervalSince1970: 2),
            bytesOut: 0, bytesIn: 0, packetCount: 1,
            tlsStatus: .plaintext, sni: nil, resolvedName: resolved, serverTLS: nil, serverCertificates: nil, clientTLS: nil, quic: nil, streamOpening: nil
        )

        XCTAssertEqual(record.name?.origin, .dns)
        XCTAssertEqual(record.name, stored.name)
    }
}
