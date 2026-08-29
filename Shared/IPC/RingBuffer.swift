import Foundation
import CTVAtomics

/// Errores del canal IPC. Ninguno se traga: el llamante decide (recrear el ring, avisar, abortar).
public enum IPCError: Error, Sendable, Equatable {
    /// No se pudo resolver el contenedor del App Group (entitlement ausente o id equivocado).
    case appGroupUnavailable
    /// Falló abrir, dimensionar o mapear el fichero del ring.
    case mapFailed
    /// La cabecera existente no es un ring compatible (magic/version/tamaño incoherentes).
    case badHeader
}

/// Constantes de layout y validación del ring, compartidas por productor y consumidor.
enum RingLayout {
    static let magic: UInt32 = 0x5456_5231   // "TVR1"
    static let version: UInt32 = 1
    static let fileName = "live-ring.bin"

    /// Región reservada antes de los slots (la fija el módulo C, alineada a línea de caché).
    static var headerBytes: Int { Int(tvring_header_bytes()) }

    static func fileSize(slotSize: Int, slotCount: Int) -> Int {
        headerBytes + slotSize * slotCount
    }

    /// Mapea un fichero de ring. Con `create` fija tamaño y cabecera para (slotSize, slotCount);
    /// sin él, abre uno existente y valida su cabecera. Devuelve el mapeo listo para usar.
    static func map(
        fileURL: URL,
        create: (slotSize: Int, slotCount: Int)?
    ) throws -> Mapping {
        let path = fileURL.path
        let creating = create != nil

        if creating {
            // Arranque de sesión: (re)crea el fichero desde cero. `createFile` trunca si existía.
            guard FileManager.default.createFile(atPath: path, contents: nil) else {
                throw IPCError.mapFailed
            }
        } else if !FileManager.default.fileExists(atPath: path) {
            throw IPCError.mapFailed
        }

        let fd = open(path, O_RDWR)
        guard fd >= 0 else { throw IPCError.mapFailed }

        // Serializa la inicialización frente a otro proceso que abra a la vez.
        flock(fd, LOCK_EX)

        let mapSize: Int
        if let create {
            mapSize = fileSize(slotSize: create.slotSize, slotCount: create.slotCount)
            guard ftruncate(fd, off_t(mapSize)) == 0 else {
                flock(fd, LOCK_UN); close(fd)
                throw IPCError.mapFailed
            }
        } else {
            var st = stat()
            guard fstat(fd, &st) == 0, Int(st.st_size) >= headerBytes else {
                flock(fd, LOCK_UN); close(fd)
                throw IPCError.badHeader
            }
            mapSize = Int(st.st_size)
        }

        let base = mmap(nil, mapSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        flock(fd, LOCK_UN)
        // El mapeo sobrevive al cierre del descriptor en Darwin; no se retiene el fd.
        close(fd)
        guard let base, base != MAP_FAILED else { throw IPCError.mapFailed }

        let slotSize: Int
        let slotCount: Int
        if let create {
            tvring_init(base, magic, version, UInt32(create.slotSize), UInt32(create.slotCount))
            slotSize = create.slotSize
            slotCount = create.slotCount
        } else {
            guard tvring_magic(base) == magic, tvring_version(base) == version else {
                munmap(base, mapSize)
                throw IPCError.badHeader
            }
            slotSize = Int(tvring_slot_size(base))
            slotCount = Int(tvring_slot_count(base))
            guard slotSize >= PackedPacketMeta.packedByteCount,
                  slotCount > 0, (slotCount & (slotCount - 1)) == 0,
                  mapSize >= fileSize(slotSize: slotSize, slotCount: slotCount) else {
                munmap(base, mapSize)
                throw IPCError.badHeader
            }
        }

        return Mapping(base: base, mapSize: mapSize, slotSize: slotSize, slotCount: slotCount)
    }

    /// Resultado de mapear: base del mapeo, su tamaño, y la geometría de slots ya validada.
    struct Mapping {
        let base: UnsafeMutableRawPointer
        let mapSize: Int
        let slotSize: Int
        let slotCount: Int

        var slotsBase: UnsafeMutableRawPointer { base.advanced(by: RingLayout.headerBytes) }
        var mask: UInt64 { UInt64(slotCount) - 1 }
    }
}

/// Lado productor del ring (usado en la extensión). Un único hilo empuja registros; nunca bloquea:
/// si el ring está lleno cuenta el descarte (back-pressure) y sigue.
///
/// `@unchecked Sendable`: cada instancia la usa **un solo** hilo (contrato SPSC); se marca así solo
/// para poder confinarla a una `Task`/`Thread` dedicada. La coordinación con el consumidor es vía
/// atómicos sobre la memoria compartida, no sobre el estado de esta clase. Compartir una instancia
/// entre varios productores rompe el protocolo.
public final class RingBufferProducer: @unchecked Sendable {
    private let mapping: RingLayout.Mapping
    private var closed = false

    public convenience init(appGroupID: String, slotCount: Int, slotSize: Int = PackedPacketMeta.packedByteCount) throws {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw IPCError.appGroupUnavailable
        }
        try self.init(fileURL: dir.appendingPathComponent(RingLayout.fileName), slotCount: slotCount, slotSize: slotSize)
    }

    /// Crea/reinicia el ring en `fileURL`. Expuesto para tests (respaldo por fichero temporal).
    public init(fileURL: URL, slotCount: Int, slotSize: Int = PackedPacketMeta.packedByteCount) throws {
        precondition(slotCount > 0 && (slotCount & (slotCount - 1)) == 0, "slotCount debe ser potencia de dos")
        precondition(slotSize >= PackedPacketMeta.packedByteCount, "slotSize no cabe un registro empaquetado")
        self.mapping = try RingLayout.map(fileURL: fileURL, create: (slotSize, slotCount))
    }

    /// Escribe un registro. Si el ring está lleno, incrementa `dropped` y descarta (nunca sobrescribe
    /// un slot no leído ni bloquea el read loop de la extensión).
    public func push(_ meta: PackedPacketMeta) {
        if closed { return }
        let base = mapping.base
        let head = tvring_head_relaxed(base)
        let tail = tvring_tail_acquire(base)
        if head &- tail >= UInt64(mapping.slotCount) {
            tvring_dropped_incr(base)
            return
        }
        let slot = mapping.slotsBase.advanced(by: Int(head & mapping.mask) * mapping.slotSize)
        meta.encode(into: slot)
        // Publica el slot ya escrito: el consumidor solo verá `head` avanzado tras el encode.
        tvring_head_store_release(base, head &+ 1)
    }

    public func close() {
        if closed { return }
        closed = true
        munmap(mapping.base, mapping.mapSize)
    }
}

/// Lado consumidor del ring (usado en la app). Drena sin bloquear los registros disponibles y avanza
/// `tail`. Mismas garantías SPSC y misma justificación de `@unchecked Sendable` que el productor.
public final class RingBufferConsumer: @unchecked Sendable {
    private let mapping: RingLayout.Mapping
    private var closed = false

    public convenience init(appGroupID: String) throws {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw IPCError.appGroupUnavailable
        }
        try self.init(fileURL: dir.appendingPathComponent(RingLayout.fileName))
    }

    /// Abre un ring existente en `fileURL` y valida su cabecera. Expuesto para tests.
    public init(fileURL: URL) throws {
        self.mapping = try RingLayout.map(fileURL: fileURL, create: nil)
    }

    /// Drena hasta `max` registros disponibles, en orden, y avanza `tail`. No bloquea.
    public func drain(max: Int) -> [PackedPacketMeta] {
        if closed || max <= 0 { return [] }
        let base = mapping.base
        let tail = tvring_tail_relaxed(base)
        // Observa el slot ya publicado por el productor (empareja el release de `head`).
        let head = tvring_head_acquire(base)
        let available = Int(head &- tail)
        guard available > 0 else { return [] }

        let count = Swift.min(available, max)
        var out: [PackedPacketMeta] = []
        out.reserveCapacity(count)
        var cursor = tail
        for _ in 0..<count {
            let slot = mapping.slotsBase.advanced(by: Int(cursor & mapping.mask) * mapping.slotSize)
            out.append(PackedPacketMeta(from: slot))
            cursor &+= 1
        }
        // Libera los slots leídos para el productor solo tras copiarlos todos.
        tvring_tail_store_release(base, cursor)
        return out
    }

    /// Registros descartados por desbordamiento desde el arranque del ring (estadística).
    public func droppedCount() -> UInt64 {
        closed ? 0 : tvring_dropped_relaxed(mapping.base)
    }

    public func close() {
        if closed { return }
        closed = true
        munmap(mapping.base, mapping.mapSize)
    }
}
