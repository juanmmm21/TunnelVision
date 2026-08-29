import Foundation

// Solo de Debug, como el resto de `Shared/Fixtures` y por la misma razón, agravada aquí: estos
// números dicen *qué está haciendo el túnel ahora mismo*, así que unos inventados delante de un
// usuario serían un diagnóstico falso sobre su propio dispositivo.
#if DEBUG

/// Los contadores de una sesión sintética, para poder **mirar** *Session diagnostics* sin un túnel.
///
/// Existe por lo mismo que `CaptureFixture` —en Simulator la extensión no corre, así que la app no
/// tiene nada que enseñar— pero cubre el hueco que aquel no alcanza: los datos de esta pantalla no
/// salen del contenedor compartido sino del canal de control, así que sembrar el historial la deja
/// exactamente igual de vacía. Era la única pantalla de la app que no se podía ver entera desde una
/// sesión de Simulator, y por tanto la única cuya densidad y jerarquía había que juzgar a ciegas.
///
/// **No hay azar aquí**: son constantes escritas a mano, y eso es lo que las hace útiles. Cada una
/// tiene que ser creíble *y* consistente con las demás —los descifrados, los pinneados y los fallidos
/// suman las terminaciones abiertas, y ésas más los abandonos y los saltos suman los candidatos—,
/// porque una tabla cuyas cifras no cuadran entre sí no sirve para juzgar cómo se leen.
///
/// Retrata **una sesión que funciona**: el túnel reenvía, resuelve nombres y descifra. Lo que no es
/// perfecto en ella tampoco es una avería inventada, sino lo que un iPhone de verdad produce — hosts
/// que rechazan el certificado (ADR 0003: eso es el producto cumpliendo lo que promete), flujos sin
/// nombre porque hablan QUIC, y un fallo de captura que es justo el caso por el que esta pantalla
/// tiene una sección de errores.
public enum TunnelStatsFixture {

    /// Los DNS anunciados. Documentación reservada (RFC 5737 y RFC 3849) como el resto de las
    /// direcciones del sembrador: estas capturas acaban en las capturas de pantalla del showcase.
    private static let announcedResolvers = ["192.0.2.53", "2001:db8::53"]

    public static func make() -> TunnelStats {
        TunnelStats(pipeline: pipeline(), relay: relay(), resolvers: resolvers())
    }

    /// El DNS de una sesión que se llevó el teléfono de casa a la calle: dos cambios de red, y uno de
    /// ellos trajo resolvers distintos. `reportedNow` repite lo anunciado porque es lo que el sistema
    /// contesta con el túnel de interfaz primario — comprobado en hardware, ver `ResolverStatus`.
    private static func resolvers() -> ResolverStatus {
        ResolverStatus(
            announced: announcedResolvers,
            reportedWhenAnnounced: announcedResolvers,
            reportedNow: announcedResolvers,
            networkChanges: 2,
            resolversRelearned: 1,
            reannounceFailures: 0
        )
    }

    private static func relay() -> RelayStats {
        var stats = RelayStats()

        stats.udpFlowsOpened = 1_284
        stats.datagramsSentOutbound = 18_452
        stats.datagramsReinjected = 17_903
        stats.emitterFailures = 0
        stats.connectionsClosed = 1_190
        stats.connectionFailures = 14
        stats.unsupportedPackets = 63

        stats.dnsQueriesSent = 412
        stats.dnsRepliesReceived = 409

        stats.tcpFlowsOpened = 336
        stats.tcpFlowsClosed = 318
        stats.tcpSegmentsReinjected = 24_117
        stats.tcpBytesToServer = 3_842_115
        stats.tcpResetsToDevice = 21

        // Dos de cada tres flujos hacia el 443 se quedan sin nombre, que es lo que se midió en el
        // iPhone: la mayoría del tráfico de 2026 es QUIC y su ClientHello va dentro del Initial.
        stats.sniObserved = 214
        stats.sniUnavailable = 122

        // 96 + 38 + 7 = 141 terminaciones abiertas; 141 + 44 + 13 = 198 candidatos.
        stats.inspectionCandidates = 198
        stats.terminationsOpened = 141
        stats.inspectionsAbandoned = 44
        stats.pinnedHostSkips = 13
        stats.flowsInspected = 96
        stats.flowsPinned = 38
        stats.terminationsFailed = 7
        stats.terminationsRolledBack = 6

        stats.plaintextChunksObserved = 1_902
        stats.plaintextChunksDropped = 8

        return stats
    }

    private static func pipeline() -> PipelineStats {
        var stats = PipelineStats()

        stats.packetsHandled = 61_248
        stats.packetsDropped = 340
        stats.bytesHandled = 48_215_907
        stats.flowsPersisted = 1_620
        stats.packetsPersisted = 60_908
        stats.reinjectedRecordsDropped = 122

        stats.storeFailures = 0
        stats.captureFailures = 1
        stats.capturesReclaimed = 2
        stats.retentionFailures = 0

        // 1902 entregados menos los 8 que la cola no aceptó.
        stats.plaintextChunksStored = 1_894
        stats.plaintextBytesStored = 5_912_064
        stats.plaintextBytesDropped = 1_048_576
        stats.plaintextChunksExpired = 210
        stats.plaintextFilesReclaimed = 6
        stats.plaintextFailures = 0

        // El texto de un `NSError` de verdad, con sus comillas tipográficas y su nombre de fichero:
        // es copia del sistema y no nuestra, y esta pantalla existe en parte para poder citarlo.
        stats.lastCaptureError = """
            The file “capture-0004.pcap” couldn’t be saved in the folder “Captures” because there is \
            not enough space on the volume.
            """

        return stats
    }
}

#endif
