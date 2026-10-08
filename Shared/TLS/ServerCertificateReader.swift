import Foundation

/// Lee de un certificado X.509 en DER lo que se apunta de él: sujeto, emisor y caducidad.
///
/// Es la mitad de **lectura** de `X509`, que solo sabe escribir los de la CA local, y lee mucho
/// menos de lo que aquél escribe: recorre el principio del TBSCertificate hasta el sujeto y no
/// mira la clave, las extensiones ni la firma. **No valida nada** —ni la firma, ni las fechas, ni
/// que el emisor de uno sea el sujeto del siguiente—: el certificado es de un tercero y lo que se
/// hace con él es citarlo.
///
/// No se usa `SecCertificate` porque en iOS no expone ni el emisor ni la validez, y porque esto
/// corre en la extensión sobre bytes que elige el otro extremo: un lector propio, acotado y sin
/// estado, se puede probar byte a byte.
public enum ServerCertificateReader {

    /// `nil` si los bytes no se dejan recorrer como un certificado hasta su sujeto.
    ///
    /// - Parameter maxNameLength: tope, en caracteres, del texto de cada nombre; lo que pase se
    ///   recorta y se marca (`CertificateName.isTruncated`).
    public static func certificate(fromDER der: ArraySlice<UInt8>, maxNameLength: Int) -> ServerCertificate? {
        var outer = DERReader(der)
        guard let certificate = outer.content(tag: DERReader.Tag.sequence) else { return nil }
        var fields = DERReader(certificate)
        guard let tbsContent = fields.content(tag: DERReader.Tag.sequence) else { return nil }

        var tbs = DERReader(tbsContent)
        // La versión es opcional: un certificado v1 no la lleva.
        if tbs.nextTag == DERReader.Tag.explicitZero {
            guard tbs.element() != nil else { return nil }
        }
        guard tbs.content(tag: DERReader.Tag.integer) != nil,       // serialNumber
              tbs.content(tag: DERReader.Tag.sequence) != nil,      // signature
              let issuer = tbs.content(tag: DERReader.Tag.sequence),
              let validity = tbs.content(tag: DERReader.Tag.sequence),
              let subject = tbs.content(tag: DERReader.Tag.sequence)
        else { return nil }

        var dates = DERReader(validity)
        guard dates.element() != nil,                               // notBefore
              let notAfterElement = dates.element(),
              let notAfter = time(notAfterElement),
              let issuerName = name(issuer, maxLength: maxNameLength),
              let subjectName = name(subject, maxLength: maxNameLength)
        else { return nil }

        return ServerCertificate(subject: subjectName, issuer: issuerName, notAfter: notAfter)
    }

    // MARK: - Name (RFC 5280 § 4.1.2.4, escrito como RFC 4514)

    /// Los nombres cortos de RFC 4514 § 3. Un atributo que no está aquí se escribe por su OID.
    private static let attributeShortNames: [String: String] = [
        "2.5.4.3": "CN",
        "2.5.4.7": "L",
        "2.5.4.8": "ST",
        "2.5.4.10": "O",
        "2.5.4.11": "OU",
        "2.5.4.6": "C",
        "2.5.4.9": "STREET",
        "0.9.2342.19200300.100.1.25": "DC",
        "0.9.2342.19200300.100.1.1": "UID",
    ]

    /// Un Name como texto de RFC 4514: los RDN en orden **inverso** al del certificado (el más
    /// específico primero), separados por comas, y los atributos de un RDN múltiple por `+`.
    static func name(_ content: ArraySlice<UInt8>, maxLength: Int) -> CertificateName? {
        var rdns: [String] = []
        var sequence = DERReader(content)
        while !sequence.isAtEnd {
            guard let rdn = sequence.content(tag: DERReader.Tag.set) else { return nil }
            var attributes: [String] = []
            var set = DERReader(rdn)
            while !set.isAtEnd {
                guard let pair = set.content(tag: DERReader.Tag.sequence) else { return nil }
                var reader = DERReader(pair)
                guard let type = reader.content(tag: DERReader.Tag.objectIdentifier),
                      let dotted = objectIdentifier(type),
                      let value = reader.element()
                else { return nil }
                attributes.append((attributeShortNames[dotted] ?? dotted) + "=" + attributeValue(value))
            }
            guard !attributes.isEmpty else { return nil }
            rdns.append(attributes.joined(separator: "+"))
        }

        let text = rdns.reversed().joined(separator: ",")
        let kept = String(text.prefix(max(0, maxLength)))
        return CertificateName(text: kept, isTruncated: kept.count < text.count)
    }

    /// El valor de un atributo, ya escapado. Un tipo que no es una cadena, o una cadena que no se
    /// deja decodificar, se escribe como `#` y el hexadecimal de su TLV (RFC 4514 § 2.4), que es
    /// decir lo que había sin interpretarlo.
    private static func attributeValue(_ element: DERReader.Element) -> String {
        let bytes = Data(element.content)
        let decoded: String?
        switch element.tag {
        case DERReader.Tag.utf8String, DERReader.Tag.printableString, DERReader.Tag.ia5String,
             DERReader.Tag.numericString, DERReader.Tag.visibleString:
            decoded = String(data: bytes, encoding: .utf8)
        case DERReader.Tag.teletexString:
            // T.61 en rigor; en los certificados que lo usan es, en la práctica, Latin-1.
            decoded = String(data: bytes, encoding: .isoLatin1)
        case DERReader.Tag.bmpString:
            decoded = bytes.count.isMultiple(of: 2) ? String(data: bytes, encoding: .utf16BigEndian) : nil
        case DERReader.Tag.universalString:
            decoded = bytes.count.isMultiple(of: 4) ? String(data: bytes, encoding: .utf32BigEndian) : nil
        default:
            decoded = nil
        }
        guard let decoded else { return "#" + hex(element.raw) }
        return escaped(decoded)
    }

    /// Escapa un valor para que no pueda leerse como estructura ni mover el texto de alrededor:
    /// los caracteres especiales de RFC 4514 § 2.4 con una barra, y todo lo que no se ve —de
    /// control, de formato (los cambios de dirección de escritura entre ellos), separadores de
    /// línea, uso privado, sin asignar— como `\XX` por cada byte de su UTF-8.
    static func escaped(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var result = ""
        for (offset, scalar) in scalars.enumerated() {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned:
                result += hexEscaped(scalar)
                continue
            default:
                break
            }
            let isEdgeSpace = scalar == " " && (offset == 0 || offset == scalars.count - 1)
            let isLeadingHash = scalar == "#" && offset == 0
            if isEdgeSpace || isLeadingHash || Self.specialCharacters.contains(scalar) {
                result += "\\"
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private static let specialCharacters: Set<Unicode.Scalar> = ["\"", "+", ",", ";", "<", ">", "\\"]

    private static func hexEscaped(_ scalar: Unicode.Scalar) -> String {
        String(scalar).utf8.map { "\\" + hexByte($0) }.joined()
    }

    private static func hex(_ bytes: ArraySlice<UInt8>) -> String {
        bytes.map(hexByte).joined()
    }

    private static func hexByte(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }

    // MARK: - OBJECT IDENTIFIER

    /// Un arco de más bytes que estos no cabe en un `UInt64`: 9 grupos de 7 bits son 63.
    private static let maxArcBytes = 9

    /// El OID con puntos, o `nil` si está vacío o un arco no termina o no cabe.
    static func objectIdentifier(_ content: ArraySlice<UInt8>) -> String? {
        guard !content.isEmpty else { return nil }
        var arcs: [UInt64] = []
        var value: UInt64 = 0
        var arcBytes = 0
        for byte in content {
            arcBytes += 1
            guard arcBytes <= maxArcBytes else { return nil }
            value = value << 7 | UInt64(byte & 0x7F)
            guard byte & 0x80 == 0 else { continue }
            if arcs.isEmpty {
                // El primer subidentificador funde los dos primeros arcos: 40 · a + b, con a ≤ 2.
                let first = min(value / 40, 2)
                arcs.append(first)
                arcs.append(value - first * 40)
            } else {
                arcs.append(value)
            }
            value = 0
            arcBytes = 0
        }
        // Un último byte con el bit de continuación deja un arco a medias.
        guard arcBytes == 0 else { return nil }
        return arcs.map { String($0) }.joined(separator: ".")
    }

    // MARK: - Time (RFC 5280 § 4.1.2.5)

    /// Un `UTCTime` (`YYMMDDHHMMSSZ`) o un `GeneralizedTime` (`YYYYMMDDHHMMSSZ`). RFC 5280 obliga
    /// a esas dos formas exactas —con segundos, en UTC y sin fracciones—, y otra cosa no se adivina.
    static func time(_ element: DERReader.Element) -> Date? {
        let yearDigits: Int
        switch element.tag {
        case DERReader.Tag.utcTime: yearDigits = 2
        case DERReader.Tag.generalizedTime: yearDigits = 4
        default: return nil
        }
        let bytes = Array(element.content)
        guard bytes.count == yearDigits + 11, bytes.last == UInt8(ascii: "Z") else { return nil }

        var fields: [Int] = []
        var position = 0
        for width in [yearDigits, 2, 2, 2, 2, 2] {
            var field = 0
            for byte in bytes[position..<(position + width)] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
                field = field * 10 + Int(byte - UInt8(ascii: "0"))
            }
            fields.append(field)
            position += width
        }

        var year = fields[0]
        if yearDigits == 2 {
            // RFC 5280: un año de dos cifras desde 50 es 19YY, y por debajo 20YY.
            year += year >= 50 ? 1900 : 2000
        }
        let (month, day, hour, minute, second) = (fields[1], fields[2], fields[3], fields[4], fields[5])
        guard (1...12).contains(month), (1...31).contains(day),
              hour <= 23, minute <= 59, second <= 59
        else { return nil }

        let seconds = daysFromEpoch(year: year, month: month, day: day) * 86_400
            + hour * 3_600 + minute * 60 + second
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Días desde el 1970-01-01 de una fecha del calendario gregoriano proléptico. Aritmética
    /// pura en vez de `Calendar`: no depende de la zona ni del calendario del dispositivo, y esto
    /// corre por cada certificado en la extensión.
    private static func daysFromEpoch(year: Int, month: Int, day: Int) -> Int {
        // El año empieza en marzo para que el día bisiesto caiga al final.
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
