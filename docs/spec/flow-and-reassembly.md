# Spec — Flow table and TCP reassembly (`PacketTunnel/Flow`)

Two components. `FlowTable` tracks every flow's aggregate state under a hard size cap.
`TCPReassembler` reconstructs an ordered byte stream for the flows we actually inspect. Both
are bounded — memory safety here is the difference between a working extension and one the OS
kills.

## FlowTable

```swift
public actor FlowTable {
    public struct Config: Sendable {
        public var maxFlows: Int            // p. ej. 4096; tope duro
        public var idleTimeout: UInt64      // ns sin tráfico ⇒ candidato a evicción
    }

    public init(config: Config, clock: MonotonicClock)

    /// Registra un paquete en su flujo (creándolo si es nuevo) y devuelve el estado vivo.
    /// Si la tabla está llena, evicta el flujo menos usado recientemente (LRU) antes de crear.
    @discardableResult
    public func observe(_ packet: ParsedPacket, direction: Direction, length: UInt32) -> LiveFlow

    /// Marca el estado de inspección TLS de un flujo (lo fija el pipeline TLS).
    public func setTLSStatus(_ status: TLSInspectionStatus, for key: FlowKey, sni: String?)

    /// Anota el host que el flujo anunció en su ClientHello (lo lee el relay del stream saliente,
    /// vía `SNIObserving` → `PacketPipeline.observe(sni:for:)`). **No toca `tlsStatus`**: saber a
    /// quién llama un flujo no es haberlo inspeccionado. No-op si el flujo ya no está en la tabla,
    /// que es lo que pasa si el nombre llega después de cerrarse.
    public func setSNI(_ sni: String, for key: FlowKey)

    /// Flujos evictados/cerrados desde la última llamada, para volcarlos al store y liberar.
    public func drainClosed() -> [FlowRecord]

    /// Cierra por inactividad; llamado periódicamente por un timer del provider.
    public func expireIdle(now: UInt64) -> [FlowRecord]
}

/// Estado vivo de un flujo mientras está en la tabla.
public struct LiveFlow: Sendable {
    public let key: FlowKey
    public var record: FlowRecord
    public var reassembler: TCPReassembler?   // presente solo si es TCP y está bajo inspección
    public var lastActivity: UInt64
}
```

**Eviction:** intrusive LRU (a doubly linked list of keys + a dictionary) so `observe` is
O(1). On overflow, evict the LRU flow, emit its `FlowRecord` via `drainClosed`, and free its
reassembler. TCP flows that see `FIN`+`FIN` or `RST` close promptly regardless of LRU.

## TCPReassembler

Only instantiated for flows selected for inspection (opt-in TLS on, port 443, not yet known to
be pinned) or for plaintext TCP we decode. Pure passthrough TCP is **not** reassembled — that
would waste the memory budget for no benefit.

```swift
public struct TCPReassembler: Sendable {
    public struct Config: Sendable {
        public var maxBufferedBytes: Int    // tope por flujo (p. ej. 256 KiB)
        public var maxOutOfOrderSegments: Int
    }

    public enum Outcome: Sendable {
        case delivered(Data)          // bytes nuevos, en orden, listos para la capa superior
        case buffered                 // segmento fuera de orden, guardado, aún no entregable
        case duplicate                // retransmisión ya vista, ignorada
        case downgraded               // se superó el tope ⇒ abandonar reensamblado, pasar a metadata
    }

    public init(config: Config, isn: UInt32, direction: Direction)

    /// Alimenta un segmento (para un sentido). Devuelve qué pudo entregarse en orden.
    public mutating func accept(sequence: UInt32, payload: Data, flags: TCPFlags) -> Outcome
}
```

### Algorithm

- Track `nextExpectedSeq` per direction (seeded from the SYN's ISN + 1).
- **In order** (`sequence == nextExpectedSeq`): deliver payload, advance `nextExpectedSeq`,
  then splice any buffered segments now contiguous and deliver them too.
- **Ahead** (`sequence > nextExpectedSeq`): buffer in a sequence-ordered structure, respecting
  `maxOutOfOrderSegments` and `maxBufferedBytes`.
- **Behind / overlap** (`sequence + len <= nextExpectedSeq`): duplicate/retransmit ⇒ ignore;
  partial overlap ⇒ trim already-delivered bytes, deliver the remainder.
- **Sequence wraparound:** compare with modular (serial-number) arithmetic per RFC 1982, not
  plain `<`/`>`, because `UInt32` sequence numbers wrap.
- **Overflow:** if buffering this segment would exceed a cap, return `.downgraded`; the flow's
  `tlsStatus`/handling drops to metadata-only and the reassembler is released. Never grow past
  the cap.

## Why bounded, always

A single misbehaving or adversarial flow (huge gap, then a flood of out-of-order segments)
could otherwise exhaust the ~tens-of-MB extension budget and get the whole extension killed,
dropping the user's connectivity. Every buffer here has a hard ceiling and a defined
degradation (downgrade to metadata) rather than unbounded growth.

## Tests (M4)

- In-order stream reassembles to the original bytes.
- Out-of-order (reversed, interleaved) reassembles correctly once gaps fill.
- Duplicate/retransmit and partial overlap handled without double-delivery.
- Sequence wraparound across the `UInt32` boundary.
- Overflow returns `.downgraded` and frees memory; a 10k-flow storm keeps `FlowTable` at or
  under `maxFlows` with bounded total memory.
- LRU eviction emits the correct `FlowRecord` and O(1) behaviour under load.
