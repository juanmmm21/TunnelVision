import Foundation

/// Con qué **empezó** el cliente un stream TCP: lo que se reconoció en los primeros bytes que el
/// dispositivo mandó por la conexión, en el puerto que sea.
///
/// Existe porque el puerto no dice qué viaja por él. `TLSInspectionStatus` nace del puerto —el 443
/// es `encrypted` y todo lo demás `plaintext`—, así que por sí solo no distingue un HTTP al 80 de
/// un TLS al 5223. Esto sí es una observación: alguien miró los bytes.
///
/// Son tres casos y el tercero no es «en claro»: un protocolo que no es ni TLS ni HTTP puede ir
/// cifrado a su manera (SSH, Noise) o no, y de él no se afirma nada. Un flujo en el que el cliente
/// no llegó a mandar bytes suficientes para decidir no tiene lectura.
public enum StreamOpening: String, Sendable, Hashable, Codable, CaseIterable {
    /// Un record de handshake de TLS con un ClientHello: el cliente empezó a negociar TLS.
    case tlsHandshake
    /// Una línea de petición de HTTP legible (`método SP destino SP HTTP/x.y`): HTTP sin cifrar.
    case httpRequest
    /// Ni lo uno ni lo otro.
    case unrecognised
}
