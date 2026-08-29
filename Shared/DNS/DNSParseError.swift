import Foundation

/// Por qué unos bytes no se leen como un mensaje de DNS.
///
/// Los tres son estructurales y **ninguno es "este tipo de registro no lo entiendo"**: un tipo
/// desconocido se lee igual y su contenido se queda como `DNSRecordData.opaque`. Un error aquí
/// significa que lo que hay delante no es un mensaje de DNS, o que se acabó antes de tiempo.
public enum DNSParseError: Error, Sendable, Equatable {

    /// Ni siquiera hay cabecera: son doce bytes y no están.
    case tooShort(expected: Int, got: Int)

    /// El mensaje se corta en medio de un nombre, de una pregunta o de un registro. Es lo que produce
    /// un `snaplen` que recortó el datagrama, y por eso la pantalla lo distingue de lo demás.
    case truncated

    /// Un nombre imposible: una etiqueta con los dos bits altos en un valor reservado, un puntero de
    /// compresión que no apunta hacia atrás, una cadena de punteros demasiado larga, o un nombre por
    /// encima de los 255 bytes que el formato permite.
    case malformedName
}
