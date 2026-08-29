import Foundation
import XCTest
import Shared

/// Tests de la lectura de cabeceras de la pantalla de un paquete (M11): qué se enseña de un datagrama,
/// qué se calla y qué se dice cuando no se puede leer.
///
/// Se ejercita sobre los mismos datagramas sintéticos que el parser (`PacketFixtures`), porque lo que
/// se afirma aquí no es el parseo —eso ya está probado en `PacketParserTests`— sino las decisiones de
/// pantalla que se toman encima: que un puerto que no existe no se invente, que un acuse sin ACK no se
/// enseñe, y que una secuencia no se agrupe con separador de miles.
final class PacketHeaderPresentationTests: XCTestCase {

    // MARK: - Utilidades

    private func record(_ bytes: Data, originalLength: UInt32? = nil) -> CaptureRecord {
        CaptureRecord(
            location: CaptureLocation(fileSequence: 3, recordOffset: 24),
            bytes: bytes,
            originalLength: originalLength ?? UInt32(bytes.count),
            timestampMicroseconds: 1_000
        )
    }

    private func facts(_ bytes: Data) throws -> [FlowFact] {
        guard case .facts(let facts, _) = PacketHeaderPresentation.content(for: record(bytes)) else {
            throw XCTSkip("se esperaban cabeceras leídas")
        }
        return facts
    }

    /// El aviso de la capa que se quedó sin leer, o `nil` si se leyó todo lo que había.
    private func unread(_ bytes: Data) throws -> String? {
        guard case .facts(_, let unread) = PacketHeaderPresentation.content(for: record(bytes)) else {
            throw XCTSkip("se esperaban cabeceras leídas")
        }
        return unread
    }

    /// Un datagrama de verdad con el payload que se le pida, emitido con el mismo serializador que usa
    /// el relay: lo que se lee en estos tests son bytes, no una estructura montada a mano.
    private func datagram(payload: Data, port: UInt16 = 53) throws -> Data {
        try PacketEmitter.udp(
            source: IPEndpoint(address: IPAddress(version: .v4, bytes: [10, 0, 0, 2]), port: 53_535),
            destination: IPEndpoint(address: IPAddress(version: .v4, bytes: [192, 0, 2, 53]), port: port),
            payload: payload
        )
    }

    private func value(_ facts: [FlowFact], _ id: String) -> String? {
        guard case .text(let text)? = facts.first(where: { $0.id == id })?.value else { return nil }
        return text
    }

    // MARK: - Lo que se lee

    func testReadsTheHeadersOfAnIPv4TCPPacket() throws {
        let facts = try facts(PacketFixtures.ipv4TcpSyn())

        XCTAssertEqual(value(facts, "headerVersion"), "IPv4")
        XCTAssertEqual(value(facts, "headerFrom"), "10.0.0.2:51000")
        XCTAssertEqual(value(facts, "headerTo"), "93.184.216.34:443")
        XCTAssertEqual(value(facts, "headerProtocol"), "TCP")
    }

    func testReadsTheHeadersOfAnIPv6TCPPacket() throws {
        let facts = try facts(PacketFixtures.ipv6Tcp())

        XCTAssertEqual(value(facts, "headerVersion"), "IPv6")
        // Los corchetes son de `IPEndpoint`: sin ellos, los dos puntos del puerto y los de la dirección
        // se leerían igual.
        XCTAssertEqual(value(facts, "headerFrom"), "[2001:db8::1]:50000")
        XCTAssertEqual(value(facts, "headerTo"), "[2001:db8::2]:443")
    }

    func testReadsThroughIPv6ExtensionHeaders() throws {
        // La cadena de next-header la recorre el parser; lo que se afirma aquí es que la pantalla nombra
        // el transporte que hay **al final** de la cadena y no la primera extensión.
        let facts = try facts(PacketFixtures.ipv6ExtHeadersTcp())

        XCTAssertEqual(value(facts, "headerProtocol"), "TCP")
        XCTAssertEqual(value(facts, "headerTo"), "[2001:db8::2]:8080")
    }

    func testTheUDPDatagramLengthComesFromTheHeaderAndNotFromTheBytes() throws {
        let facts = try facts(PacketFixtures.ipv4UdpDns())

        XCTAssertEqual(value(facts, "headerProtocol"), "UDP")
        // Cabecera UDP (8) + payload (4). Es lo que el campo declara, que es lo real aunque la captura
        // recorte.
        XCTAssertEqual(value(facts, "udpLength"), DisplayFormat.bytes(12))
        XCTAssertNil(value(facts, "tcpSequence"), "un datagrama UDP no tiene secuencia que enseñar")
    }

    // MARK: - Lo que no se inventa

    func testAPacketWithoutPortsShowsBareAddresses() throws {
        // ICMP no tiene puertos: `IPEndpoint` traería un `:0` que nadie ha puesto en el cable.
        let facts = try facts(PacketFixtures.ipv4Icmp())

        XCTAssertEqual(value(facts, "headerFrom"), "93.184.216.34")
        XCTAssertEqual(value(facts, "headerTo"), "10.0.0.2")
        XCTAssertEqual(value(facts, "headerProtocol"), "ICMP")
    }

    func testANonFirstFragmentShowsBareAddressesToo() throws {
        // Un fragmento que no es el primero no lleva cabecera de transporte: sus bytes son continuación
        // del payload, así que tampoco hay puertos que enseñar.
        let facts = try facts(PacketFixtures.ipv4NonFirstFragment())

        XCTAssertEqual(value(facts, "headerFrom"), "10.0.0.2")
        XCTAssertNil(value(facts, "tcpSequence"))
    }

    func testTheAcknowledgmentIsOnlyShownWhenTheACKFlagIsSet() throws {
        let syn = try facts(PacketFixtures.ipv4TcpSyn())
        XCTAssertNil(value(syn, "tcpAcknowledgment"), "sin ACK el campo son 32 bits sin usar")

        let pshAck = try facts(PacketFixtures.ipv6Tcp())
        XCTAssertEqual(value(pshAck, "tcpAcknowledgment"), "16909060")
    }

    /// Una secuencia **identifica** una posición en el flujo de bytes: agruparla la convertiría en una
    /// cantidad, y `1.234.567.890` no es un número de secuencia. La ventana sí es una cantidad y va
    /// formateada como tal — las dos juntas en un test porque la afirmación es el contraste.
    func testASequenceIsNotGroupedButAWindowIs() throws {
        let facts = try facts(PacketFixtures.ipv4TcpSyn())

        XCTAssertEqual(value(facts, "tcpSequence"), "305419896")
        XCTAssertEqual(value(facts, "tcpWindow"), DisplayFormat.bytes(65_535))
    }

    /// El tamaño y los flags ya los dicen los datos guardados del paquete: repetirlos leídos del cable
    /// invitaría a compararlos como si pudieran discrepar. El payload no sale porque los rangos del
    /// parser están acotados al buffer y en un registro recortado contarían lo guardado, no lo que viajó.
    func testItDoesNotRepeatWhatTheStoredMetadataAlreadySays() throws {
        let facts = try facts(PacketFixtures.ipv4TcpSyn())
        let ids = Set(facts.map(\.id))

        XCTAssertFalse(ids.contains("size"))
        XCTAssertFalse(ids.contains("flags"))
        XCTAssertFalse(ids.contains("headerPayload"))
    }

    /// La rejilla se lee **por filas**, así que dos datos que son las dos mitades de una cosa tienen
    /// que caer uno al lado del otro. `From` y `To` no lo hacían: con la versión primera y el protocolo
    /// cuarto, de dónde venía quedaba arriba a la derecha y a dónde iba abajo a la izquierda — los dos
    /// extremos de un viaje leídos en diagonal, que es el mismo defecto que la cabecera del Flow
    /// Inspector acababa de perder.
    func testTheTwoEndsOfTheJourneyAreNeighboursAndNotADiagonal() throws {
        for bytes in [PacketFixtures.ipv4TcpSyn(), PacketFixtures.ipv6Tcp(), PacketFixtures.ipv4UdpDns()] {
            let ids = try facts(bytes).map(\.id)
            let from = try XCTUnwrap(ids.firstIndex(of: "headerFrom"))

            XCTAssertEqual(ids[from + 1], "headerTo", "los dos extremos se leen en diagonal: \(ids)")
            // Y empiezan fila: en dos columnas, la primera mitad de una pareja va en índice par.
            XCTAssertEqual(from % 2, 0, "«From» es la segunda columna de su fila: \(ids)")
            XCTAssertEqual(Array(ids.prefix(2)), ["headerVersion", "headerProtocol"])
        }
    }

    func testEveryFactHasItsOwnIdentity() throws {
        // La rejilla los pinta en un `ForEach`: dos ids iguales dejarían uno sin dibujar.
        let facts = try facts(PacketFixtures.ipv6Tcp())

        XCTAssertEqual(Set(facts.map(\.id)).count, facts.count)
    }

    // MARK: - DNS, que es la capa que este paquete lleva encima

    func testADNSQueryIsBrokenDownInTheSameGrid() throws {
        let facts = try facts(
            datagram(payload: DNSMessageFixture.query(id: 1, name: "api.example.com", type: .a))
        )

        // Sin pantalla nueva: entra detrás de lo que ya decía la rejilla, que es exactamente lo que la
        // segunda pasada estética la dejó preparada para admitir.
        let ids = facts.map(\.id)
        XCTAssertEqual(Array(ids.prefix(5)), ["headerVersion", "headerProtocol", "headerFrom", "headerTo", "udpLength"])
        XCTAssertEqual(Array(ids.dropFirst(5)), ["dnsKind", "dnsName", "dnsRecordType"])

        XCTAssertEqual(value(facts, "dnsName"), "api.example.com")
        XCTAssertEqual(value(facts, "dnsRecordType"), "A")
        XCTAssertNil(try unread(datagram(payload: DNSMessageFixture.query(id: 1, name: "a.test", type: .a))))
    }

    /// Las dos mitades de la pregunta —qué nombre y de qué tipo— se leen **en la misma fila**, que es
    /// la misma regla por la que `From` y `To` dejaron de leerse en diagonal. Sale del orden y del
    /// número impar de datos que van delante (cinco, en todo datagrama UDP), así que se afirma: un
    /// dato más arriba las separaría sin que nada aquí cambiase.
    func testTheTwoHalvesOfTheQuestionAreNeighbours() throws {
        let reply = DNSMessageFixture.reply(
            id: 1, name: "api.example.com", type: .a,
            answers: [.address(IPAddress(version: .v4, bytes: [203, 0, 113, 10]))]
        )
        let ids = try facts(datagram(payload: reply)).map(\.id)
        let name = try XCTUnwrap(ids.firstIndex(of: "dnsName"))

        XCTAssertEqual(ids[name + 1], "dnsRecordType", "la pregunta se lee en diagonal: \(ids)")
        XCTAssertEqual(name % 2, 0, "«Looked up» es la segunda columna de su fila: \(ids)")
        // Y la respuesta es lo último, que es donde va lo que no tiene pareja conceptual.
        XCTAssertEqual(ids.last, "dnsAnswer")
    }

    func testADNSReplyShowsWhatTheNameResolvedTo() throws {
        let reply = DNSMessageFixture.reply(
            id: 1, name: "api.example.com", type: .a,
            answers: [.address(IPAddress(version: .v4, bytes: [203, 0, 113, 10]))]
        )
        let facts = try facts(datagram(payload: reply))

        // El titular del incremento: donde antes solo ponía «UDP · Datagram length: 76 B».
        XCTAssertEqual(value(facts, "dnsAnswer"), "203.0.113.10")
    }

    func testPortFiftyThreeThatIsNotDNSSaysSoInsteadOfGoingQuiet() throws {
        // Las cabeceras IP y UDP se leen perfectamente, así que esto no cae en `.undecodable` y sin el
        // aviso el DNS desaparecería de la pantalla sin explicación — que es como se lee una avería
        // intermitente.
        let bytes = try datagram(payload: Data(repeating: 0x2a, count: 40))

        XCTAssertNil(try facts(bytes).first { $0.id.hasPrefix("dns") })
        let note = try XCTUnwrap(try unread(bytes))
        XCTAssertTrue(note.contains("port 53"), note)
    }

    func testTruncatedBytesOnPortFiftyThreeOfferTheSettingThatFixesIt() throws {
        let whole = try datagram(
            payload: DNSMessageFixture.reply(
                id: 1, name: "api.example.com", type: .a,
                answers: [.address(IPAddress(version: .v4, bytes: [203, 0, 113, 10]))]
            )
        )
        let clipped = record(whole.prefix(32), originalLength: UInt32(whole.count))

        guard case .facts(_, let unread) = PacketHeaderPresentation.content(for: clipped) else {
            return XCTFail("las cabeceras IP y UDP caben en 32 bytes")
        }
        let note = try XCTUnwrap(unread)
        XCTAssertTrue(note.contains("Settings"), note)
    }

    func testAUDPDatagramThatIsNotDNSGetsNothingExtraAndNoNote() throws {
        let bytes = try datagram(payload: Data(repeating: 0x2a, count: 40), port: 443)

        XCTAssertNil(try facts(bytes).first { $0.id.hasPrefix("dns") })
        XCTAssertNil(try unread(bytes), "aquí no se ha dejado de leer nada: nadie prometió leer QUIC")
    }

    // MARK: - Cuando no se puede leer

    func testTooFewSavedBytesSayWhatWasSavedAndWhereToChangeIt() {
        let full = PacketFixtures.ipv4TcpSyn()
        // Solo los ocho primeros bytes: ni la cabecera IPv4 entera cabe. El registro sabe que se recortó
        // porque su `originalLength` es el del paquete de verdad.
        let clipped = record(full.prefix(8), originalLength: UInt32(full.count))

        guard case .undecodable(let note) = PacketHeaderPresentation.content(for: clipped) else {
            return XCTFail("ocho bytes no dan para leer una cabecera")
        }
        XCTAssertTrue(note.contains(DisplayFormat.bytes(8)), "dice cuánto se guardó")
        XCTAssertTrue(note.contains("Settings"), "y dónde se cambia, que es lo único accionable")
    }

    func testCompleteBytesThatDoNotParseSayTheOtherThing() {
        // Nibble de versión 0: no es IPv4 ni IPv6, y no falta nada — así que no se ofrece un ajuste que
        // no arreglaría esto.
        let nonsense = Data(repeating: 0x0f, count: 64)

        guard case .undecodable(let note) = PacketHeaderPresentation.content(for: record(nonsense)) else {
            return XCTFail("eso no es un datagrama")
        }
        XCTAssertFalse(note.contains("Settings"))
        XCTAssertTrue(note.contains("IP packet"))
    }

    // MARK: - Copia

    /// Los dos que este fichero puede perder sin que ningún test de contenido se entere: una llamada que
    /// pierde su `defaultValue` devuelve **la clave**, y una clave estructural se lee inocente en un
    /// diff y luego sale en pantalla.
    func testNoStringIsAKeyOrCarriesStrayWhitespace() throws {
        let query = try datagram(payload: DNSMessageFixture.query(id: 1, name: "api.example.com", type: .a))
        let reply = try datagram(
            payload: DNSMessageFixture.reply(
                id: 1, name: "api.example.com", type: .a,
                answers: [.address(IPAddress(version: .v4, bytes: [203, 0, 113, 10]))]
            )
        )
        let facts = try facts(PacketFixtures.ipv6Tcp()) + facts(query) + facts(reply)
        var strings = facts.map(\.label)
        strings.append(PacketHeaderPresentation.headersSectionTitle)
        strings.append(contentsOf: [
            try XCTUnwrap(unread(datagram(payload: Data(repeating: 0x2a, count: 40)))),
            DNSPresentation.unreadNote(
                for: record(Data(repeating: 0, count: 40), originalLength: 300)
            ),
        ])
        // Los valores del DNS también son copia —"Question", "No such name"—, al revés que una
        // dirección o el nombre de un tipo de registro.
        strings.append(contentsOf: facts.compactMap { fact -> String? in
            guard fact.id == "dnsKind" || fact.id == "dnsAnswer" else { return nil }
            guard case .text(let text) = fact.value else { return nil }
            return text
        })

        for string in strings {
            XCTAssertFalse(string.hasPrefix("packetDetail."), "\(string) es la clave, no la copia")
            XCTAssertEqual(string, string.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertFalse(string.contains("  "), "\(string) tiene un espacio doble")
        }
    }
}
