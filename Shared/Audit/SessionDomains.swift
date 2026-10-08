import Foundation

/// Una versión de TLS vista en las conexiones a un dominio, con los flujos que la llevan.
///
/// Lleva la observación entera —la versión **y de dónde salió**— porque quien la cite tiene que
/// citar las dos cosas: la que negoció la conexión del túnel no es la que negoció la app.
public struct TLSVersionSighting: Sendable, Hashable {
    public let observation: TLSVersionObservation

    /// En el orden en que ocurrieron. Nunca vacío.
    public let flowIDs: [Int64]

    public init(observation: TLSVersionObservation, flowIDs: [Int64]) {
        self.observation = observation
        self.flowIDs = flowIDs
    }
}

/// Lo que una sesión deja decir de un dominio: qué flujos fueron a él y cuáles solo **pudieron**.
///
/// Las dos listas no son la misma cosa con distinta confianza. Un flujo va en `flowIDs` cuando su
/// nombre no tiene alternativa: lo anunció la conexión (SNI) o se dedujo del DNS de una dirección
/// que solo tenía ese nombre. Va en `candidateFlowIDs` cuando el nombre se dedujo de una dirección
/// que compartían varios: el flujo fue a uno de ellos y no se sabe a cuál, así que cuenta como
/// candidato de todos —también del que se le atribuyó— y como visto de ninguno. Es la regla de
/// `HostAssessment`: un ganador no habla por los demás candidatos.
public struct DomainObservation: Sendable, Hashable {

    /// Normalizado (`DomainPattern.normalised(host:)`), como lo cita un hallazgo.
    public let host: String

    /// Los flujos que fueron a este dominio, como ocurrieron.
    public let flowIDs: [Int64]

    /// Los flujos que pudieron ir a este dominio o a otro de los que compartían su dirección.
    public let candidateFlowIDs: [Int64]

    /// Las versiones de TLS leídas en `flowIDs`, cada una con su origen, en el orden en que
    /// apareció por primera vez. Los candidatos no cuentan: su versión es de la conexión, y de
    /// la conexión no se sabe a qué dominio iba.
    public let tlsSightings: [TLSVersionSighting]

    /// Los de `flowIDs` que no dejan leer ninguna versión de TLS: porque no lo llevan, o porque
    /// la respuesta del servidor no se leyó. Aquí no se distingue; lo hace `TLSVersionAssessment`.
    public let flowIDsWithoutTLSReading: [Int64]

    public init(
        host: String,
        flowIDs: [Int64],
        candidateFlowIDs: [Int64],
        tlsSightings: [TLSVersionSighting],
        flowIDsWithoutTLSReading: [Int64]
    ) {
        self.host = host
        self.flowIDs = flowIDs
        self.candidateFlowIDs = candidateFlowIDs
        self.tlsSightings = tlsSightings
        self.flowIDsWithoutTLSReading = flowIDsWithoutTLSReading
    }

    /// Si algún flujo de la sesión fue a este dominio sin alternativa. Con `false` el dominio
    /// solo aparece como candidato, y de si la sesión lo contactó no se afirma nada.
    public var isSeen: Bool { !flowIDs.isEmpty }
}

/// Los dominios de una sesión: a dónde fueron sus flujos, por nombre.
///
/// Es puro y no compara nada: es el inventario de **un** lado, lo que el diff entre releases pone
/// frente al de otra sesión. El nombre de un flujo es su `FlowName` —nunca la columna `sni`—,
/// normalizado, así que el dominio de aquí es el mismo texto que el host de un hallazgo.
public struct SessionDomains: Sendable, Hashable {

    /// En el orden en que cada dominio apareció por primera vez, como visto o como candidato.
    public let domains: [DomainObservation]

    /// Los flujos sin nombre. No tienen dominio y no desaparecen del inventario: cualquiera de
    /// ellos pudo ir a un dominio que aquí no figura, y quien lea el inventario tiene que saber
    /// cuántos son. Por qué no tienen nombre lo dice `HostAssessment`.
    public let unnamedFlowIDs: [Int64]

    public init(domains: [DomainObservation], unnamedFlowIDs: [Int64]) {
        self.domains = domains
        self.unnamedFlowIDs = unnamedFlowIDs
    }

    /// - Parameter flows: **todos** los flujos de una sesión de auditoría, en el orden del
    ///   historial (`FlowStore.flows(inAuditSession:limit:)`: como ocurrieron). Una lista
    ///   recortada da un inventario al que le faltan dominios sin que nada lo diga.
    public init(flows: [StoredFlow]) {
        var inventory = Inventory()
        var unnamed: [Int64] = []
        for flow in flows {
            guard let name = flow.name else {
                unnamed.append(flow.id)
                continue
            }
            let candidates = Self.candidates(of: name)
            if candidates.count == 1, let host = candidates.first {
                inventory.addFlow(flow, to: host)
            } else {
                for host in candidates {
                    inventory.addCandidate(flow.id, to: host)
                }
            }
        }
        self.init(domains: inventory.entries.map(\.observation), unnamedFlowIDs: unnamed)
    }

    /// Los nombres a los que el flujo pudo ir, normalizados y sin repetir, el atribuido primero.
    /// Un candidato que normalizado es el mismo nombre que otro no es una alternativa.
    private static func candidates(of name: FlowName) -> [String] {
        var seen: Set<String> = []
        return ([name.text] + name.otherCandidates)
            .map(DomainPattern.normalised(host:))
            .filter { seen.insert($0).inserted }
    }

    /// Acumula por dominio conservando el orden de primera aparición: el de un informe no puede
    /// depender de un hash.
    private struct Inventory {
        private(set) var entries: [Entry] = []
        private var indices: [String: Int] = [:]

        mutating func addFlow(_ flow: StoredFlow, to host: String) {
            let index = index(of: host)
            entries[index].flowIDs.append(flow.id)
            if let observation = TLSVersionObservation(of: flow) {
                entries[index].addSighting(observation, flowID: flow.id)
            } else {
                entries[index].flowIDsWithoutTLSReading.append(flow.id)
            }
        }

        mutating func addCandidate(_ flowID: Int64, to host: String) {
            entries[index(of: host)].candidateFlowIDs.append(flowID)
        }

        private mutating func index(of host: String) -> Int {
            if let index = indices[host] { return index }
            indices[host] = entries.count
            entries.append(Entry(host: host))
            return entries.count - 1
        }
    }

    private struct Entry {
        let host: String
        var flowIDs: [Int64] = []
        var candidateFlowIDs: [Int64] = []
        var sightings: [(observation: TLSVersionObservation, flowIDs: [Int64])] = []
        var flowIDsWithoutTLSReading: [Int64] = []

        mutating func addSighting(_ observation: TLSVersionObservation, flowID: Int64) {
            if let index = sightings.firstIndex(where: { $0.observation == observation }) {
                sightings[index].flowIDs.append(flowID)
            } else {
                sightings.append((observation: observation, flowIDs: [flowID]))
            }
        }

        var observation: DomainObservation {
            DomainObservation(
                host: host,
                flowIDs: flowIDs,
                candidateFlowIDs: candidateFlowIDs,
                tlsSightings: sightings.map { TLSVersionSighting(observation: $0.observation, flowIDs: $0.flowIDs) },
                flowIDsWithoutTLSReading: flowIDsWithoutTLSReading
            )
        }
    }
}
