import Foundation
import XCTest
import Shared

/// Tests del canal de control (M7, movido a `Shared/IPC` en M9). El transporte
/// (`sendProviderMessage`/`handleAppMessage`) es device-only, pero el codec no: app y extensión se
/// compilan por separado y solo se encuentran en ejecución, así que lo que hay que probar aquí es que
/// ambos lados hablan el mismo idioma y que un mensaje ajeno se rechaza en vez de interpretarse.
final class ControlChannelTests: XCTestCase {

    // MARK: - Round-trip de comandos

    func testEveryCommandSurvivesTheRoundTrip() throws {
        let commands: [ControlCommand] = [
            .setTLSInspectionEnabled(true),
            .setTLSInspectionEnabled(false),
            .setCaptureEnabled(true),
            .setCaptureEnabled(false),
            .setCaptureDetail(.metadataOnly),
            .setCaptureDetail(.fullPayload),
            .setPlaintextPersistenceEnabled(true),
            .setPlaintextPersistenceEnabled(false),
            .rotateCapture,
            .stats
        ]

        for command in commands {
            let decoded = try ControlCommand(decoding: try command.encoded())
            XCTAssertEqual(decoded, command)
        }
    }

    /// El booleano del comando es su carga útil: si se perdiera, un toggle de "apagar inspección"
    /// podría llegar como "encender" y decodificar tráfico sin consentimiento.
    func testCommandPayloadIsNotConfusedBetweenCases() throws {
        let off = try ControlCommand(decoding: try ControlCommand.setTLSInspectionEnabled(false).encoded())
        XCTAssertEqual(off, .setTLSInspectionEnabled(false))
        XCTAssertNotEqual(off, .setTLSInspectionEnabled(true))
        XCTAssertNotEqual(off, .setCaptureEnabled(false))
        // Y sobre todo no puede confundirse con el otro interruptor de la inspección: apagar que se
        // *guarde* lo descifrado y apagar que se *descifre* son dos actos distintos (ADR 0007), y
        // aplicar uno por el otro dejaría grabando algo que el usuario acaba de prohibir.
        XCTAssertNotEqual(off, .setPlaintextPersistenceEnabled(false))
    }

    // MARK: - Round-trip de respuestas

    func testSimpleResponsesSurviveTheRoundTrip() throws {
        for response in [ControlResponse.ok, .notRunning, .failed("disco lleno")] {
            let decoded = try ControlResponse(decoding: try response.encoded())
            XCTAssertEqual(decoded, response)
        }
    }

    /// Los contadores son lo único con estructura que cruza el canal; se comprueban campo a campo,
    /// incluidos los textos de error opcionales.
    func testPipelineStatsSurviveTheRoundTripWithEveryField() throws {
        var stats = PipelineStats()
        stats.packetsHandled = 9_001
        stats.packetsDropped = 3
        stats.bytesHandled = 12_345_678
        stats.flowsPersisted = 42
        stats.packetsPersisted = 8_900
        stats.storeFailures = 1
        stats.captureFailures = 2
        stats.plaintextChunksStored = 17
        stats.plaintextBytesStored = 65_536
        stats.plaintextBytesDropped = 4_096
        stats.plaintextFailures = 1
        stats.lastPlaintextError = "writeFailed"
        stats.lastStoreError = "database is locked"
        stats.lastCaptureError = "writeFailed"

        let sent = TunnelStats(pipeline: stats)
        let decoded = try ControlResponse(decoding: try ControlResponse.stats(sent).encoded())

        guard case .stats(let roundTripped) = decoded else {
            return XCTFail("se esperaba .stats, llegó \(decoded)")
        }
        XCTAssertEqual(roundTripped.pipeline, stats)
    }

    /// La otra mitad de la respuesta, y la que contesta "¿por qué no se inspecciona nada?": se
    /// comprueba entera porque un contador que se pierda por el camino se lee como un cero, y un cero
    /// aquí es una afirmación ("no pasó") y no una ausencia.
    func testRelayStatsSurviveTheRoundTripWithEveryField() throws {
        var relay = RelayStats()
        relay.udpFlowsOpened = 11
        relay.datagramsSentOutbound = 22
        relay.datagramsReinjected = 33
        relay.emitterFailures = 1
        relay.connectionsClosed = 9
        relay.connectionFailures = 2
        relay.unsupportedPackets = 4
        relay.tcpFlowsOpened = 55
        relay.tcpFlowsClosed = 54
        relay.tcpSegmentsReinjected = 6_000
        relay.tcpBytesToServer = 7_777_777
        relay.tcpResetsToDevice = 3
        relay.sniObserved = 40
        relay.sniUnavailable = 15
        relay.inspectionCandidates = 30
        relay.terminationsOpened = 20
        relay.inspectionsAbandoned = 8
        relay.pinnedHostSkips = 2
        relay.flowsInspected = 17
        relay.flowsPinned = 2
        relay.terminationsFailed = 1
        relay.plaintextChunksObserved = 120
        relay.plaintextChunksDropped = 5

        let sent = TunnelStats(pipeline: PipelineStats(), relay: relay)
        let decoded = try ControlResponse(decoding: try ControlResponse.stats(sent).encoded())

        guard case .stats(let roundTripped) = decoded else {
            return XCTFail("se esperaba .stats, llegó \(decoded)")
        }
        XCTAssertEqual(roundTripped.relay, relay)
        XCTAssertEqual(roundTripped, sent)
    }

    /// El estado del DNS viaja entero, y las dos ausencias que lleva dentro **siguen siendo
    /// ausencias**: "no se pudo preguntar" llega como `nil` y no como lista vacía, que es lo que
    /// separa una avería nuestra de una red sin resolvers.
    func testTheResolverStatusSurvivesTheRoundTripWithItsAbsencesIntact() throws {
        let sent = TunnelStats(
            pipeline: PipelineStats(),
            relay: RelayStats(),
            resolvers: ResolverStatus(
                announced: ["192.168.1.1", "2001:db8::53"],
                reportedWhenAnnounced: ["192.168.1.1", "2001:db8::53", "fe80::1"],
                reportedNow: nil
            )
        )
        let decoded = try ControlResponse(decoding: try ControlResponse.stats(sent).encoded())

        guard case .stats(let roundTripped) = decoded else {
            return XCTFail("se esperaba .stats, llegó \(decoded)")
        }
        XCTAssertEqual(roundTripped.resolvers?.announced, ["192.168.1.1", "2001:db8::53"])
        XCTAssertEqual(roundTripped.resolvers?.reportedWhenAnnounced, ["192.168.1.1", "2001:db8::53", "fe80::1"])
        XCTAssertNil(roundTripped.resolvers?.reportedNow)
        XCTAssertEqual(roundTripped, sent)
    }

    /// Y una respuesta sin esa mitad no puede llegar como "no anunció ninguno", que es exactamente el
    /// fallo que estos campos existen para hacer visible.
    func testAnAbsentResolverStatusArrivesAbsentAndNotAsAnEmptyAnnouncement() throws {
        let decoded = try ControlResponse(decoding: try ControlResponse.stats(TunnelStats()).encoded())

        guard case .stats(let stats) = decoded else {
            return XCTFail("se esperaba .stats, llegó \(decoded)")
        }
        XCTAssertNil(stats.resolvers)
        XCTAssertNotEqual(stats, TunnelStats(pipeline: PipelineStats(), resolvers: ResolverStatus()))
    }

    /// Los errores opcionales viajan como ausentes cuando no hay error, no como cadena vacía: la app
    /// distingue "nunca falló" de "falló con un mensaje vacío".
    func testStatsResponseKeepsAbsentErrorsAbsent() throws {
        let decoded = try ControlResponse(decoding: try ControlResponse.stats(TunnelStats()).encoded())

        guard case .stats(let stats) = decoded else {
            return XCTFail("se esperaba .stats, llegó \(decoded)")
        }
        XCTAssertNil(stats.pipeline.lastStoreError)
        XCTAssertNil(stats.pipeline.lastCaptureError)
        XCTAssertNil(stats.pipeline.lastPlaintextError)
        XCTAssertEqual(stats.pipeline, PipelineStats())
    }

    /// Un relay ausente no puede llegar como un relay a cero: el primero es "no había a quien
    /// preguntar" (el túnel estaba parándose) y el segundo es "no se inspeccionó nada en toda la
    /// sesión", que es exactamente el diagnóstico que estos contadores existen para dar.
    func testAnAbsentRelayArrivesAbsentAndNotAsZeroes() throws {
        let decoded = try ControlResponse(decoding: try ControlResponse.stats(TunnelStats()).encoded())

        guard case .stats(let stats) = decoded else {
            return XCTFail("se esperaba .stats, llegó \(decoded)")
        }
        XCTAssertNil(stats.relay)
        XCTAssertNotEqual(stats, TunnelStats(pipeline: PipelineStats(), relay: RelayStats()))
    }

    // MARK: - Entradas ajenas

    /// `handleAppMessage` recibe bytes arbitrarios: cualquiera con el App Group puede escribirle.
    /// Un mensaje que no es de este canal debe fallar de forma tipada, nunca colarse como comando.
    func testGarbageIsRejectedAsMalformed() {
        let garbage: [Data] = [
            Data(),                                   // vacío
            Data([0x00, 0x01, 0x02, 0x03]),           // binario que no es JSON
            Data("{}".utf8),                          // JSON válido, no es un comando
            Data(#"{"setTLSInspectionEnabled":{}}"#.utf8),   // caso conocido, payload incompleto
            Data(#"{"enableRootkit":{"_0":true}}"#.utf8)     // comando inexistente
        ]

        for data in garbage {
            XCTAssertThrowsError(try ControlCommand(decoding: data)) { error in
                XCTAssertEqual(error as? ControlMessageError, .malformed)
            }
        }
    }

    func testGarbageIsRejectedAsMalformedOnTheResponseSide() {
        XCTAssertThrowsError(try ControlResponse(decoding: Data("no soy json".utf8))) { error in
            XCTAssertEqual(error as? ControlMessageError, .malformed)
        }
    }

    /// Una respuesta no es un comando: cada dirección del canal tiene su propio tipo y no deben
    /// intercambiarse silenciosamente.
    func testACommandDoesNotDecodeAsAResponse() throws {
        let commandData = try ControlCommand.rotateCapture.encoded()
        XCTAssertThrowsError(try ControlResponse(decoding: commandData))
    }
}
