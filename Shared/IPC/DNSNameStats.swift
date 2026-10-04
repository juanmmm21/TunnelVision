import Foundation

/// Qué ha hecho el túnel con las respuestas de DNS que ha visto pasar, y a cuántos flujos les ha
/// puesto nombre con ellas.
///
/// Existe para que **«no hubo DNS que leer» se pueda decir**. Con DNS cifrado (DoH, DoT, Private
/// Relay) no cruza ninguna respuesta por el puerto 53, y entonces todos estos contadores se quedan a
/// cero: esa es la explicación de una sesión entera de flujos sin nombre, y sin ella la ausencia de
/// nombres se leería como una avería.
///
/// Vive en `Shared/IPC` por lo mismo que `PipelineStats`, dentro del cual viaja: cruza el canal de
/// control.
public struct DNSNameStats: Sendable, Equatable, Codable {

    /// Respuestas de las que se apuntó al menos una dirección.
    public var repliesRecorded: UInt64 = 0
    /// Direcciones apuntadas entre todas ellas.
    public var addressesRecorded: UInt64 = 0

    /// Datagramas llegados del puerto 53 que el disector no pudo leer como un mensaje de DNS:
    /// cortados, o que no lo eran.
    public var unreadable: UInt64 = 0

    // Un contador por cada `DNSNameIngestion.Reason`: mensajes legibles que no apuntaron nada.
    public var notAResponse: UInt64 = 0
    public var unsupportedOpcode: UInt64 = 0
    public var errorResponses: UInt64 = 0
    public var unsupportedQuestions: UInt64 = 0
    public var unusableNames: UInt64 = 0
    public var withoutAddresses: UInt64 = 0

    /// Flujos que nacieron con un nombre resuelto.
    public var flowsNamed: UInt64 = 0

    public init() {}

    /// Mensajes legibles que no apuntaron nada, por el motivo que fuera.
    public var repliesIgnored: UInt64 {
        notAResponse &+ unsupportedOpcode &+ errorResponses
            &+ unsupportedQuestions &+ unusableNames &+ withoutAddresses
    }

    /// Anota el desenlace de dárselo al mapa de nombres.
    public mutating func count(_ ingestion: DNSNameIngestion) {
        switch ingestion {
        case .recorded(let addresses):
            repliesRecorded &+= 1
            addressesRecorded &+= UInt64(addresses)
        case .ignored(.notAResponse): notAResponse &+= 1
        case .ignored(.unsupportedOpcode): unsupportedOpcode &+= 1
        case .ignored(.errorResponse): errorResponses &+= 1
        case .ignored(.unsupportedQuestion): unsupportedQuestions &+= 1
        case .ignored(.unusableName): unusableNames &+= 1
        case .ignored(.noAddresses): withoutAddresses &+= 1
        }
    }
}
