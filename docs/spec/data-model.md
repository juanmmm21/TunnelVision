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
    public var resolvedName: ResolvedFlowName?   // el nombre que el DNS daba a la dirección remota
    public var serverTLS: ServerTLSAnswer?   // lo que el servidor contestó al ClientHello, si se leyó
    public var name: FlowName? { get }  // el nombre con su origen: el SNI, y si no el resuelto
}

/// Lo que el servidor contestó al ClientHello de un flujo (`relay-and-tls.md` § *What the server
/// chose*). Una negativa también es una respuesta; lo que no dice nada del servidor es `nil`.
public enum ServerTLSAnswer: Sendable, Hashable, Codable {
    case negotiated(NegotiatedTLS)      // versión, suite y si salió de un HelloRetryRequest
    case refused(alert: UInt8)          // el código de la alerta, tal cual
}

/// El nombre que un flujo recibió al crearse de las respuestas de DNS vistas por el túnel.
public struct ResolvedFlowName: Sendable, Hashable, Codable {
    public let name: String             // el nombre por el que se preguntó, normalizado
    public let otherNames: [String]     // los demás nombres vivos de esa dirección, el más reciente primero
}

public enum FlowNameOrigin: Sendable, Hashable { case sni, dns }

/// El nombre de un flujo con su origen.
public struct FlowName: Sendable, Hashable {
    public let text: String
    public let origin: FlowNameOrigin
    public let otherCandidates: [String]   // solo los trae un nombre deducido del DNS
    public init?(sni: String?, resolved: ResolvedFlowName?)
}
```

### A flow has two names, and they are not the same kind of fact

`sni` is what the connection **announced** in its ClientHello. `resolvedName` is an **inference**:
the name the device had last asked for when it was given the address the flow goes to
([`packet-parsing.md`](packet-parsing.md) § *Names from DNS*). They are separate fields and separate
columns, and a resolved name is never written into `sni`: a report has to be able to say which of the
two it is asserting.

`FlowName` is what a reader uses when it needs *a* name per flow — an allowlist, a release diff, a
report. Its rules:

- **The SNI wins whenever there is one.** It is the connection's own statement; the resolution is a
  guess about an address that may be shared.
- **The origin is derived, not stored**: it is which of the two fields is set. A stored origin would
  be a second place to say the same thing, free to disagree with the first.
- **Only a name from DNS has `otherCandidates`.** When the SNI wins they are dropped: the connection
  has said which one it was.
- A flow with neither has no name (`nil`), and is reported as unnamed rather than left out.

### What the server answered is not the inspection status

`serverTLS` and `tlsStatus` are independent. `tlsStatus` says what TunnelVision did with the flow
(left it encrypted, inspected it, found it not inspectable); `serverTLS` says what the **server**
chose, read from a ServerHello that travels in the clear. A flow is `encrypted` with a negotiated
TLS 1.3, and setting one never changes the other. `nil` means there was no reading — the flow was not
TLS over TCP/443, the stream could not be read, the flow is inspected, or the answer has not arrived
— and is never to be read as "no TLS".

## Tests to write (M1)

- `FlowKey` canonicalization: `(src,dst)` and `(dst,src)` yield equal keys;
  `direction(ofPacketFrom:localAddress:)` is correct for both endpoints and independent of the
  order the key was built in.
- `IPAddress.description` for v4 and v6 (including `::` compression edge cases).
- `Codable` round-trip for every persisted/transported type.
- `TCPFlags` set semantics.
