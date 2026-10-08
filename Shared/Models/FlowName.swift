import Foundation

/// El nombre que un flujo recibió **al crearse** de las respuestas de DNS que habían pasado por el
/// túnel: el que el dispositivo había pedido para la dirección a la que el flujo va.
///
/// Es lo que queda de un `ResolvedName` cuando se le pega a un flujo. Pierde el instante de la
/// resolución —es un sello monotónico, que no sobrevive a la sesión— y conserva lo que el informe
/// necesita: el nombre y **los demás candidatos** de una dirección compartida.
///
/// **No es un SNI y no se guarda donde el SNI.** Un SNI lo anuncia la propia conexión; esto es una
/// deducción hecha a partir de una búsqueda anterior, y quien lo lea tiene que poder distinguirlo.
public struct ResolvedFlowName: Sendable, Hashable, Codable {

    /// El nombre por el que se preguntó, normalizado (minúsculas, sin punto final).
    public let name: String

    /// Los otros nombres que la misma dirección tenía vivos en ese instante, del resuelto más
    /// recientemente al más antiguo. Vacío es que la atribución no tenía competencia. Juzgar el
    /// flujo contra una allowlist exige mirarlos: que el ganador esté autorizado no autoriza a los
    /// demás, y el flujo pudo ser de cualquiera de ellos.
    public let otherNames: [String]

    public init(name: String, otherNames: [String]) {
        self.name = name
        self.otherNames = otherNames
    }

    public init(_ resolved: ResolvedName) {
        self.init(name: resolved.name, otherNames: resolved.otherNames)
    }
}

/// De dónde sale el nombre de un flujo.
public enum FlowNameOrigin: Sendable, Hashable {
    /// Lo anunció la propia conexión en su ClientHello.
    case sni
    /// Se dedujo de una respuesta de DNS anterior al flujo.
    case dns
}

/// El nombre de un flujo **con su origen**: lo que lee quien necesita un nombre por flujo (la
/// allowlist, el diff entre releases, el informe) sin tener que saber de qué columna salió.
///
/// El origen no se guarda: se **deriva** de cuál de los dos campos del flujo está puesto. Guardarlo
/// aparte sería un segundo sitio donde decir lo mismo, con la posibilidad de que dijeran cosas
/// distintas.
public struct FlowName: Sendable, Hashable {

    public let text: String
    public let origin: FlowNameOrigin

    /// Otros nombres que el flujo pudo tener. Solo un nombre deducido del DNS los trae; un SNI es
    /// lo que la conexión dijo de sí misma y no tiene competencia.
    public let otherCandidates: [String]

    public init(text: String, origin: FlowNameOrigin, otherCandidates: [String]) {
        self.text = text
        self.origin = origin
        self.otherCandidates = otherCandidates
    }

    /// El nombre de un flujo a partir de sus dos campos, o `nil` si no tiene ninguno.
    ///
    /// **El SNI gana siempre que exista**: es una declaración de la conexión, y la resolución es una
    /// inferencia sobre una dirección que puede ser compartida. Cuando el SNI gana, los candidatos
    /// del DNS no viajan con él: ya no son alternativas, la conexión ha dicho cuál era.
    ///
    /// Un SNI vacío cuenta como que no hay: no nombra a nadie, y dejarle ganar taparía el nombre
    /// resuelto con una cadena en blanco.
    public init?(sni: String?, resolved: ResolvedFlowName?) {
        if let sni, !sni.isEmpty {
            self.init(text: sni, origin: .sni, otherCandidates: [])
        } else if let resolved {
            self.init(text: resolved.name, origin: .dns, otherCandidates: resolved.otherNames)
        } else {
            return nil
        }
    }
}
