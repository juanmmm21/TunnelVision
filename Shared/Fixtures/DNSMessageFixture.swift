import Foundation

// Solo de Debug, como el resto de `Shared/Fixtures`: esto **escribe** mensajes de DNS, y lo único
// para lo que sirve escribirlos es rellenar una captura sintética.
#if DEBUG

/// Un registro de la sección de respuestas de un mensaje sintético.
public enum DNSFixtureAnswer: Sendable, Equatable {

    /// Un A o un AAAA, según la familia de la dirección.
    case address(IPAddress)

    /// Un registro cuyo contenido es otro nombre: CNAME, PTR o NS.
    case name(String, type: DNSRecordType)

    /// Un registro cuyo contenido no se desmenuza —TXT, MX, SOA…—: se rellena con `byteCount` bytes
    /// cualesquiera, porque lo que este caso existe para producir es un registro *legal* que el
    /// disector tenga que dejar en `opaque`.
    case opaque(type: DNSRecordType, byteCount: Int)
}

/// Escribe mensajes de DNS de verdad, para que la captura sintética lleve en el puerto 53 lo que
/// llevaría un teléfono y no ruido con la forma correcta.
///
/// Existe por lo mismo que `PacketEmitter` en `CaptureFixture`: lo que la app enseña en Simulator
/// tiene que salir de **bytes reales**, o mirar una pantalla no prueba nada sobre lo que hará con un
/// paquete de verdad. Y es código independiente del parser —lo escribe, no lo lee—, así que los tests
/// que lo usan siguen afirmando algo.
///
/// Comprime el nombre de cada respuesta con un puntero a la pregunta (`0xC00C`), que es lo que hace
/// todo resolutor real y, de paso, lo que hace que el camino de punteros del parser se recorra cada
/// vez que se mira una captura sembrada.
public enum DNSMessageFixture {

    /// La clase `IN`, que es la única que se usa en internet.
    private static let internetClass: UInt16 = 1

    /// El offset de la pregunta dentro del mensaje: justo detrás de los doce bytes de cabecera. Es a
    /// donde apuntan los punteros de compresión de las respuestas.
    private static let questionOffset: UInt16 = 12

    /// Una consulta con `RD` puesto, que es la que manda un dispositivo a su resolutor.
    public static func query(id: UInt16, name: String, type: DNSRecordType) -> Data {
        var message = header(id: id, flags: 0x0100, answerCount: 0)
        message.append(question(name: name, type: type))
        return message
    }

    /// Una respuesta a esa misma pregunta, con `QR`, `RD` y `RA` puestos.
    public static func reply(
        id: UInt16,
        name: String,
        type: DNSRecordType,
        answers: [DNSFixtureAnswer],
        responseCode: DNSResponseCode = .noError,
        timeToLive: UInt32 = 300
    ) -> Data {
        var message = header(
            id: id,
            flags: 0x8180 | UInt16(responseCode.rawValue),
            answerCount: UInt16(answers.count)
        )
        message.append(question(name: name, type: type))
        for answer in answers {
            message.append(record(answer, timeToLive: timeToLive))
        }
        return message
    }

    // MARK: - Las piezas

    private static func header(id: UInt16, flags: UInt16, answerCount: UInt16) -> Data {
        var bytes = Data()
        appendU16BE(&bytes, id)
        appendU16BE(&bytes, flags)
        appendU16BE(&bytes, 1)             // una pregunta, que es lo que manda todo el mundo
        appendU16BE(&bytes, answerCount)
        appendU16BE(&bytes, 0)             // sin sección de autoridad
        appendU16BE(&bytes, 0)             // sin sección adicional
        return bytes
    }

    private static func question(name: String, type: DNSRecordType) -> Data {
        var bytes = encoded(name)
        appendU16BE(&bytes, type.rawValue)
        appendU16BE(&bytes, internetClass)
        return bytes
    }

    private static func record(_ answer: DNSFixtureAnswer, timeToLive: UInt32) -> Data {
        var bytes = Data()
        appendU16BE(&bytes, 0xc000 | questionOffset)

        let type: DNSRecordType
        let data: Data
        switch answer {
        case .address(let address):
            type = address.version == .v4 ? .a : .aaaa
            data = Data(address.bytes)
        case .name(let target, let recordType):
            type = recordType
            data = encoded(target)
        case .opaque(let recordType, let byteCount):
            precondition(byteCount >= 0, "un registro no puede medir menos que nada")
            type = recordType
            // El contenido da igual mientras la longitud cuadre: este caso existe para producir un
            // registro legal que el disector no sabe desmenuzar, no para decir algo con sus bytes.
            data = Data(repeating: 0x2a, count: byteCount)
        }

        appendU16BE(&bytes, type.rawValue)
        appendU16BE(&bytes, internetClass)
        appendU32BE(&bytes, timeToLive)
        appendU16BE(&bytes, UInt16(data.count))
        bytes.append(data)
        return bytes
    }

    /// El nombre en su forma de cable: cada etiqueta con su longitud delante y un cero al final.
    ///
    /// Las dos precondiciones son errores de programación de quien escribe el fixture y no casos que
    /// haya que tolerar: una etiqueta de más de 63 bytes o vacía **no se puede** codificar, y dejar
    /// que salieran produciría bytes que ni este formato ni ningún parser aceptan.
    private static func encoded(_ name: String) -> Data {
        var bytes = Data()
        guard name != "." else {
            bytes.append(0)
            return bytes
        }
        for label in name.split(separator: ".", omittingEmptySubsequences: false) {
            let utf8 = Array(label.utf8)
            precondition(!utf8.isEmpty, "una etiqueta vacía solo vale al final del nombre: \(name)")
            precondition(utf8.count <= 63, "etiqueta de más de 63 bytes en \(name)")
            bytes.append(UInt8(utf8.count))
            bytes.append(contentsOf: utf8)
        }
        bytes.append(0)
        return bytes
    }

    private static func appendU16BE(_ bytes: inout Data, _ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendU32BE(_ bytes: inout Data, _ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }
}

#endif
