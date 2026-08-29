# Spec — Domain data model (`Shared/Models`)

The vocabulary types shared by both processes. All are value types and `Sendable`. These are
the foundation; build them first (milestone M1) and keep them dependency-free (Foundation only).

## Design rules

- Value semantics everywhere; no reference types in this module.
- `FlowKey` is **canonical**: it identifies a connection regardless of packet direction, so
  the flow table sees both directions as one flow.
- Sizes are fixed-width integers with explicit types — these cross the process boundary and
  end up in the ring buffer and pcap, where layout matters.

## Enumerations

```swift
/// Familia de direcciones IP del paquete.
public enum IPVersion: UInt8, Sendable, Codable {
    case v4 = 4
    case v6 = 6
}

/// Número de protocolo de la capa de transporte (campo `protocol`/`next header`).
public enum IPProtocolNumber: UInt8, Sendable, Codable {
    case tcp = 6
    case udp = 17
    case icmp = 1
    case icmpv6 = 58
    case other = 255   // cualquier otro; el valor real se guarda aparte en `PacketMeta.rawProtocol`
}

/// Sentido del paquete relativo al dispositivo.
public enum Direction: UInt8, Sendable, Codable {
    case outbound = 0   // del dispositivo hacia internet
    case inbound = 1    // de internet hacia el dispositivo
}

/// Estado de inspección TLS de un flujo.
public enum TLSInspectionStatus: UInt8, Sendable, Codable {
    case plaintext = 0        // no cifrado (p. ej. HTTP)
    case encrypted = 1        // cifrado y no inspeccionado (inspección off o no es 443)
    case inspected = 2        // cifrado y descifrado con consentimiento vía CA local
    case notInspectable = 3   // rechazó nuestra CA (pinning): se relayea intacto
}
```

## Endpoints and keys

```swift
/// Dirección IP + puerto. La IP se guarda en su forma binaria (4 o 16 bytes).
/// `Comparable` da el orden total estable que usa la canonicalización de `FlowKey`
/// (por dirección y luego por puerto).
public struct IPEndpoint: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let address: IPAddress   // wrapper sobre los bytes crudos (ver abajo)
    public let port: UInt16
    public init(address: IPAddress, port: UInt16)
}

/// IP cruda; evita depender de `Network.IPv4Address` en el modelo base. `Comparable` ordena
/// primero por familia y luego lexicográficamente por los bytes.
public struct IPAddress: Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let version: IPVersion
    public let bytes: [UInt8]        // 4 para v4, 16 para v6
    public init(version: IPVersion, bytes: [UInt8])
    public var description: String { get }   // texto canónico (dotted/colon-hex)
}

/// Identidad canónica de un flujo (5-tupla), independiente del sentido del paquete.
///
/// La canonicalización ordena los dos endpoints de forma estable (`endpointA <= endpointB`)
/// para que un paquete outbound y su respuesta inbound produzcan la MISMA clave. Como la clave
/// es canónica, NO almacena nada dependiente del sentido; `direction(ofPacketFrom:localAddress:)`
/// reconstruye el sentido a partir de la dirección local del dispositivo.
public struct FlowKey: Sendable, Hashable, Codable {
    public let proto: IPProtocolNumber
    public let endpointA: IPEndpoint   // menor según orden canónico
    public let endpointB: IPEndpoint   // mayor según orden canónico

    /// Construye la clave canónica a partir del par (origen, destino) tal como vienen en el paquete.
    public init(proto: IPProtocolNumber, source: IPEndpoint, destination: IPEndpoint)

    /// Reconstruye el sentido de un paquete a partir de su endpoint origen y de la dirección IP
    /// local del dispositivo: `.outbound` si el origen es la IP local, `.inbound` si no.
    /// Requiere `localAddress` porque la clave canónica, por sí sola, no distingue cuál de los dos
    /// endpoints es el dispositivo. Precondición: `source` es uno de los dos endpoints del flujo.
    public func direction(ofPacketFrom source: IPEndpoint, localAddress: IPAddress) -> Direction
}
```

## Parsed headers (transient, on the hot path)

These are produced by the parser and consumed immediately; they are not persisted as-is.

```swift
public struct IPHeader: Sendable {
    public let version: IPVersion
    public let source: IPAddress
    public let destination: IPAddress
    public let proto: IPProtocolNumber
    public let rawProtocol: UInt8       // valor real del campo, incluso si `proto == .other`
    public let payloadRange: Range<Int> // rango del payload L4 dentro del buffer original
    public let totalLength: Int
}

public struct TCPHeader: Sendable {
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let sequence: UInt32
    public let acknowledgment: UInt32
    public let flags: TCPFlags
    public let windowSize: UInt16
    public let dataOffsetBytes: Int     // longitud de cabecera TCP (incluye opciones)
    public let payloadRange: Range<Int>
}

public struct UDPHeader: Sendable {
    public let sourcePort: UInt16
    public let destinationPort: UInt16
    public let length: UInt16
    public let payloadRange: Range<Int>
}

public struct TCPFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8)
    public static let fin = TCPFlags(rawValue: 1 << 0)
    public static let syn = TCPFlags(rawValue: 1 << 1)
    public static let rst = TCPFlags(rawValue: 1 << 2)
    public static let psh = TCPFlags(rawValue: 1 << 3)
    public static let ack = TCPFlags(rawValue: 1 << 4)
    public static let urg = TCPFlags(rawValue: 1 << 5)
}
```

## Records (persisted / transported)

```swift
/// Metadato compacto de un paquete: lo que viaja por el ring buffer y a la tabla `packets`.
/// Layout de ancho fijo — ver ipc.md para la representación empaquetada.
public struct PacketMeta: Sendable, Hashable, Codable {
    public let timestamp: UInt64        // nanosegundos monotónicos desde un origen inyectado
    public let flowKey: FlowKey
    public let direction: Direction
    public let length: UInt32           // bytes del paquete IP
    public let tcpFlags: TCPFlags       // 0 si no es TCP
    public let capture: CaptureLocation?   // dónde quedaron sus bytes, o nil si no se capturó
}

/// Dónde quedaron los bytes de un paquete. Es la pareja completa a propósito: el writer rota de
/// fichero por tamaño y cada uno reinicia sus offsets tras la cabecera global, así que un offset
/// suelto no identifica unos bytes — apunta a una posición de un fichero desconocido.
public struct CaptureLocation: Sendable, Hashable, Codable {
    public let fileSequence: UInt32     // el número del nombre del `.pcap` (ver pcap.md)
    public let recordOffset: UInt64     // offset de la cabecera del registro; nunca 0
}

/// Estado agregado de un flujo: fila de la tabla `flows`.
public struct FlowRecord: Sendable, Hashable, Codable, Identifiable {
    public let id: Int64                 // rowid asignado por el store
    public let key: FlowKey
    public let firstSeen: UInt64
    public let lastSeen: UInt64
    public var bytesOut: UInt64
    public var bytesIn: UInt64
    public var packetCount: UInt64
    public var tlsStatus: TLSInspectionStatus
    public var sni: String?             // hostname del ClientHello, si se vio
}
```

## Tests to write (M1)

- `FlowKey` canonicalization: `(src,dst)` and `(dst,src)` yield equal keys;
  `direction(ofPacketFrom:localAddress:)` is correct for both endpoints and independent of the
  order the key was built in.
- `IPAddress.description` for v4 and v6 (including `::` compression edge cases).
- `Codable` round-trip for every persisted/transported type.
- `TCPFlags` set semantics.
