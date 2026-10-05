import Foundation
import GRDB

/// Historial durable de flujos y paquetes en SQLite (GRDB) dentro del contenedor del App Group,
/// de modo que la extensión (escritura por lotes) y la app (lectura) alcancen la misma BD. El
/// `DatabasePool` abre en modo WAL, así la app lee mientras la extensión escribe.
///
/// `FlowStore` es un `actor`: toda mutación/consulta pasa por su API serializada; nunca se
/// comparte un handle `Database` crudo entre aislamientos. Ver `docs/spec/persistence.md`.
///
/// **El store es la frontera donde el tiempo se vuelve absoluto.** Lo que entra (`FlowRecord`,
/// `PacketMeta`) lleva sellos monotónicos, que es lo único que existe en el hot path; lo que se
/// guarda y lo que sale (`StoredFlow`, `StoredPacket`) va en hora de pared, porque un historial
/// fechado con el uptime deja de ser fechable y ordenable en cuanto el dispositivo se reinicia. La
/// conversión la hace el ancla que se toma al abrir: una por sesión de captura (ver
/// `MonotonicAnchor`).
public actor FlowStore {

    public enum StoreError: Error, Sendable, Equatable {
        case appGroupUnavailable
        case openFailed
        case migrationFailed
        /// Una fila almacenada no se puede reconstruir a un tipo de dominio (p. ej. un blob de
        /// dirección con longitud distinta de 4/16). Indica corrupción o un cambio de esquema mal migrado.
        case corruptRow(String)
    }

    /// Sin `private`: la mitad de auditoría del store vive en `FlowStore+Audit.swift`.
    let dbPool: DatabasePool
    private let databaseURL: URL
    private let anchor: MonotonicAnchor

    /// Identificador de la sesión de captura: el instante de apertura, en ns desde el epoch. Entra
    /// en el índice único junto a la 5-tupla, así que la misma tupla vista en dos sesiones son dos
    /// flujos distintos y no una sola fila con una duración inventada.
    private let session: Int64

    /// Abre (o crea) la BD en el contenedor del App Group indicado, aplica migraciones y deja
    /// WAL activo. Lanza `appGroupUnavailable` si el contenedor no se puede resolver (falta el
    /// entitlement o el ID es incorrecto).
    public init(appGroupID: String, anchor: MonotonicAnchor = .now()) throws {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else {
            throw StoreError.appGroupUnavailable
        }
        try self.init(
            databaseURL: container.appendingPathComponent("TunnelVision.sqlite"),
            anchor: anchor
        )
    }

    /// Abre (o crea) la BD en una URL concreta. Útil para tests (BD temporal) y para consumidores
    /// que ya hayan resuelto la ruta por su cuenta.
    ///
    /// El `anchor` se inyecta para que los tests fechen de forma determinista; en producción es el
    /// del momento de apertura, que es justo cuando empieza la sesión de captura.
    public init(databaseURL: URL, anchor: MonotonicAnchor = .now()) throws {
        self.databaseURL = databaseURL
        self.anchor = anchor
        self.session = anchor.wallClockNanoseconds
        do {
            // DatabasePool abre siempre en modo WAL: lecturas concurrentes + un único escritor.
            self.dbPool = try DatabasePool(path: databaseURL.path)
        } catch {
            throw StoreError.openFailed
        }
        do {
            try Schema.migrator().migrate(dbPool)
        } catch {
            throw StoreError.migrationFailed
        }
    }

    // MARK: - Escritura (extensión)

    /// Los estados de inspección que son un **desenlace** y no el punto de partida de un flujo,
    /// como lista de SQL. Sale del enum para que un caso nuevo no se quede fuera por un literal.
    private static let outcomeStatuses: String = [TLSInspectionStatus.inspected, .notInspectable]
        .map { String($0.rawValue) }
        .joined(separator: ", ")

    /// Inserta el flujo o, si ya existe (misma 5-tupla canónica **en esta sesión**), actualiza su
    /// estado agregado. Devuelve el `rowid` del flujo, con el que enlazar sus paquetes.
    ///
    /// Un record trae los totales acumulados de **la vida actual** del flujo en la tabla en memoria,
    /// no de la fila: la tabla suelta un flujo que calla dos minutos (o lo desaloja, o lo cierra un
    /// RST) y lo crea de nuevo desde cero si esa 5-tupla vuelve a tener tráfico. Así que la fila no
    /// se puede fijar sin más a lo que diga el record, o la segunda vida borraría la primera:
    ///
    /// - **Los contadores** son `base_*` + los del record. Una vida nueva se reconoce porque empieza
    ///   después de lo último que la fila vio (`first_seen` del record > `last_seen` de la fila; en
    ///   una misma vida es al revés por construcción), y en ese instante lo acumulado pasa a ser la
    ///   base. Los volcados siguientes de esa vida vuelven a traer acumulados, y se suman a la
    ///   misma base: una vez, no una por volcado.
    /// - **El `sni`** se conserva si el record no trae uno: el ClientHello pasó en la vida anterior.
    /// - **El `tls_status`** no baja de un desenlace (`inspected` / `notInspectable`) a un estado de
    ///   partida (`plaintext` / `encrypted`), que es con lo que nace todo flujo: no es noticia de
    ///   que la inspección se deshiciera. Un desenlace nuevo sí sustituye al anterior.
    /// - `last_seen` es el del record y `first_seen` conserva el mínimo.
    ///
    /// El **nombre resuelto por DNS** es la excepción: una fila que ya lo tiene lo conserva. Un flujo
    /// se nombra al crearse, y la tabla en memoria puede crear dos veces el mismo (lo desaloja, o
    /// caduca por inactividad, y vuelve a tener tráfico); la segunda vez el mapa de nombres puede
    /// contestar otra cosa, y el historial no puede cambiarle el nombre a una conexión a mitad. El
    /// nombre y sus otros candidatos se conservan o se sustituyen **juntos**.
    ///
    /// La **respuesta TLS del servidor** tiene la regla contraria y por la misma causa: un record
    /// que no la trae no borra la que la fila ya tiene, y uno que la trae la sustituye entera. El
    /// ServerHello se lee una vez, al principio del stream; un flujo que la tabla en memoria vuelve
    /// a crear ya no lo va a ver pasar, así que llega sin respuesta y la fila tiene que conservar la
    /// suya. Y si llega con una es que hubo un handshake nuevo sobre la misma 5-tupla, y la que vale
    /// es la última.
    ///
    /// Si hay una **sesión de auditoría abierta**, el flujo queda etiquetado con ella. La sesión se
    /// lee de la propia BD en la misma sentencia, así que la extensión no necesita que nadie le avise
    /// de que la app abrió una: la BD compartida ya es ese aviso. Un flujo que venía de antes y sigue
    /// vivo se etiqueta en su siguiente volcado —tuvo tráfico durante la sesión, y dejarlo fuera
    /// sería esconderle al informe una conexión que estaba abierta—, y uno ya etiquetado no cambia de
    /// sesión aunque sobreviva a la suya.
    @discardableResult
    public func upsertFlow(_ record: FlowRecord) throws -> Int64 {
        let key = record.key
        let session = self.session
        let firstSeen = anchor.nanosecondsSince1970(forUptime: record.firstSeen)
        let lastSeen = anchor.nanosecondsSince1970(forUptime: record.lastSeen)
        let tls = Serialization.serverTLSColumns(record.serverTLS)
        return try dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO flows
                    (session, proto, addr_a, port_a, addr_b, port_b,
                     first_seen, last_seen, bytes_out, bytes_in, packet_count, tls_status, sni,
                     dns_name, dns_other_names,
                     tls_version, tls_cipher_suite, tls_hello_retry, tls_alert, audit_session_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                        (SELECT id FROM audit_sessions WHERE ended_at IS NULL))
                ON CONFLICT (session, proto, addr_a, port_a, addr_b, port_b) DO UPDATE SET
                    last_seen = excluded.last_seen,
                    base_bytes_out = CASE WHEN excluded.first_seen > flows.last_seen
                        THEN flows.bytes_out ELSE flows.base_bytes_out END,
                    base_bytes_in = CASE WHEN excluded.first_seen > flows.last_seen
                        THEN flows.bytes_in ELSE flows.base_bytes_in END,
                    base_packet_count = CASE WHEN excluded.first_seen > flows.last_seen
                        THEN flows.packet_count ELSE flows.base_packet_count END,
                    bytes_out = excluded.bytes_out + CASE WHEN excluded.first_seen > flows.last_seen
                        THEN flows.bytes_out ELSE flows.base_bytes_out END,
                    bytes_in = excluded.bytes_in + CASE WHEN excluded.first_seen > flows.last_seen
                        THEN flows.bytes_in ELSE flows.base_bytes_in END,
                    packet_count = excluded.packet_count + CASE WHEN excluded.first_seen > flows.last_seen
                        THEN flows.packet_count ELSE flows.base_packet_count END,
                    tls_status = CASE WHEN flows.tls_status IN (\(Self.outcomeStatuses))
                            AND excluded.tls_status NOT IN (\(Self.outcomeStatuses))
                        THEN flows.tls_status ELSE excluded.tls_status END,
                    sni = COALESCE(excluded.sni, flows.sni),
                    dns_name = COALESCE(flows.dns_name, excluded.dns_name),
                    dns_other_names = CASE WHEN flows.dns_name IS NULL
                        THEN excluded.dns_other_names ELSE flows.dns_other_names END,
                    tls_version = CASE WHEN excluded.tls_version IS NULL AND excluded.tls_alert IS NULL
                        THEN flows.tls_version ELSE excluded.tls_version END,
                    tls_cipher_suite = CASE WHEN excluded.tls_version IS NULL AND excluded.tls_alert IS NULL
                        THEN flows.tls_cipher_suite ELSE excluded.tls_cipher_suite END,
                    tls_hello_retry = CASE WHEN excluded.tls_version IS NULL AND excluded.tls_alert IS NULL
                        THEN flows.tls_hello_retry ELSE excluded.tls_hello_retry END,
                    tls_alert = CASE WHEN excluded.tls_version IS NULL AND excluded.tls_alert IS NULL
                        THEN flows.tls_alert ELSE excluded.tls_alert END,
                    first_seen = min(flows.first_seen, excluded.first_seen),
                    audit_session_id = COALESCE(flows.audit_session_id, excluded.audit_session_id)
                """,
                arguments: [
                    session,
                    Int(key.proto.rawValue),
                    Data(key.endpointA.address.bytes), Int(key.endpointA.port),
                    Data(key.endpointB.address.bytes), Int(key.endpointB.port),
                    firstSeen, lastSeen,
                    Serialization.int64(record.bytesOut), Serialization.int64(record.bytesIn),
                    Serialization.int64(record.packetCount),
                    Int(record.tlsStatus.rawValue), record.sni,
                    record.resolvedName?.name,
                    Serialization.otherNames(record.resolvedName?.otherNames ?? []),
                    tls.version, tls.cipherSuite, tls.helloRetry, tls.alert,
                ]
            )
            // El UPSERT pudo ser INSERT o UPDATE; `lastInsertedRowID` solo vale para INSERT, así
            // que se resuelve el id por la clave única en la misma transacción.
            guard let id = try Int64.fetchOne(
                db,
                sql: """
                SELECT id FROM flows
                WHERE session = ? AND proto = ? AND addr_a = ? AND port_a = ? AND addr_b = ? AND port_b = ?
                """,
                arguments: [
                    session,
                    Int(key.proto.rawValue),
                    Data(key.endpointA.address.bytes), Int(key.endpointA.port),
                    Data(key.endpointB.address.bytes), Int(key.endpointB.port),
                ]
            ) else {
                throw StoreError.corruptRow("upsertFlow no recuperó el rowid del flujo recién escrito")
            }
            return id
        }
    }

    /// Inserta un lote de metadatos de paquete para un flujo, en una única transacción. Los inserts
    /// por paquete están prohibidos en el hot path: la extensión acumula y vacía por lotes.
    public func appendPackets(_ metas: [PacketMeta], flowID: Int64) throws {
        guard !metas.isEmpty else { return }
        let anchor = self.anchor
        try dbPool.write { db in
            let statement = try db.makeStatement(
                sql: """
                INSERT INTO packets (flow_id, ts, direction, length, tcp_flags, pcap_offset, pcap_file)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """
            )
            for meta in metas {
                // Sin captura se guardan los dos a 0: el offset 0 es el centinela de "sin captura"
                // (ningún registro puede vivir ahí, delante de la cabecera global del fichero).
                try statement.execute(arguments: [
                    flowID,
                    anchor.nanosecondsSince1970(forUptime: meta.timestamp),
                    Int(meta.direction.rawValue),
                    Int(meta.length),
                    Int(meta.tcpFlags.rawValue),
                    Serialization.int64(meta.capture?.recordOffset ?? 0),
                    Int64(meta.capture?.fileSequence ?? 0),
                ])
            }
        }
    }

    /// Indexa un lote de trozos de contenido descifrado ya escritos en disco, en una única
    /// transacción. Mismo contrato que `appendPackets`: por lotes, nunca uno por trozo — esto ocurre
    /// en el camino de un paquete.
    ///
    /// Los bytes no entran aquí: la fila dice **dónde** están (`docs/spec/plaintext.md`). Y el sello
    /// llega monotónico y se guarda absoluto, como el de un paquete, con el ancla de la sesión.
    public func appendPlaintext(_ chunks: [PlaintextChunkMeta], flowID: Int64) throws {
        guard !chunks.isEmpty else { return }
        let anchor = self.anchor
        try dbPool.write { db in
            let statement = try db.makeStatement(
                sql: """
                INSERT INTO plaintext
                    (flow_id, ts, direction, stream, file_seq, record_offset, stored_length, original_length)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            for chunk in chunks {
                try statement.execute(arguments: [
                    flowID,
                    anchor.nanosecondsSince1970(forUptime: chunk.timestamp),
                    Int(chunk.direction.rawValue),
                    Serialization.int64(chunk.stream),
                    Int64(chunk.location.fileSequence),
                    Serialization.int64(chunk.location.recordOffset),
                    Int64(chunk.storedLength),
                    Int64(chunk.originalLength),
                ])
            }
        }
    }

    // MARK: - Lectura (app)

    /// Flujos más recientes primero (`last_seen` desc). Con `before`, devuelve la página siguiente
    /// hacia atrás en el tiempo: solo flujos estrictamente anteriores a ese cursor.
    ///
    /// El orden es global, no por sesión: los instantes en disco son absolutos, así que un flujo de
    /// ayer se ordena bien contra uno de hoy aunque el dispositivo se haya reiniciado entre medias.
    public func recentFlows(limit: Int, before cursor: FlowCursor? = nil) throws -> [StoredFlow] {
        try dbPool.read { db in
            var sql = """
            SELECT id, proto, addr_a, port_a, addr_b, port_b,
                   first_seen, last_seen, bytes_out, bytes_in, packet_count, tls_status, sni,
                   dns_name, dns_other_names,
                   tls_version, tls_cipher_suite, tls_hello_retry, tls_alert
            FROM flows
            """
            var arguments: [DatabaseValueConvertible] = []
            if let cursor {
                // El desempate por `id` evita repetir o saltarse filas cuando varias comparten
                // `last_seen`, que con sellos de nanosegundo es raro pero no imposible.
                let lastSeen = WallClock.nanosecondsSince1970(from: cursor.lastSeen)
                sql += " WHERE last_seen < ? OR (last_seen = ? AND id < ?)"
                arguments.append(contentsOf: [lastSeen, lastSeen, cursor.id])
            }
            sql += " ORDER BY last_seen DESC, id DESC LIMIT ?"
            arguments.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return try rows.map(Serialization.storedFlow(from:))
        }
    }

    /// Paquetes de un flujo, en orden temporal ascendente. Reconstruye la `FlowKey` de cada paquete
    /// uniendo con `flows` (la tabla `packets` no duplica la 5-tupla).
    public func packets(forFlow id: Int64, limit: Int) throws -> [StoredPacket] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT p.id, p.ts, p.direction, p.length, p.tcp_flags, p.pcap_offset, p.pcap_file,
                       f.proto, f.addr_a, f.port_a, f.addr_b, f.port_b
                FROM packets p
                JOIN flows f ON f.id = p.flow_id
                WHERE p.flow_id = ?
                ORDER BY p.ts ASC, p.id ASC
                LIMIT ?
                """,
                arguments: [id, limit]
            )
            return try rows.map(Serialization.storedPacket(from:))
        }
    }

    /// El flujo **más reciente** que coincide con una 5-tupla canónica, o `nil` si no existe. Desde
    /// que la sesión entra en la clave única puede haber varios (los puertos efímeros se reciclan),
    /// y a quien pregunta por una tupla le interesa el último.
    public func flow(matching key: FlowKey) throws -> StoredFlow? {
        try dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, proto, addr_a, port_a, addr_b, port_b,
                       first_seen, last_seen, bytes_out, bytes_in, packet_count, tls_status, sni,
                       dns_name, dns_other_names,
                       tls_version, tls_cipher_suite, tls_hello_retry, tls_alert
                FROM flows
                WHERE proto = ? AND addr_a = ? AND port_a = ? AND addr_b = ? AND port_b = ?
                ORDER BY last_seen DESC, id DESC
                LIMIT 1
                """,
                arguments: [
                    Int(key.proto.rawValue),
                    Data(key.endpointA.address.bytes), Int(key.endpointA.port),
                    Data(key.endpointB.address.bytes), Int(key.endpointB.port),
                ]
            )
            return try row.map(Serialization.storedFlow(from:))
        }
    }

    /// Un flujo por su identidad de fila, o `nil` si la retención ya se lo llevó.
    ///
    /// Es lo que necesita una pantalla abierta sobre **esta** conexión para volver a leerla: por clave
    /// no vale, porque los puertos efímeros se reciclan y `flow(matching:)` devuelve el más reciente de
    /// la tupla — que puede ser otra conexión distinta, y cambiarla bajo el usuario sin decírselo sería
    /// atribuirle a lo que está mirando el tráfico de algo que no ha abierto.
    public func flow(id: Int64) throws -> StoredFlow? {
        try dbPool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, proto, addr_a, port_a, addr_b, port_b,
                       first_seen, last_seen, bytes_out, bytes_in, packet_count, tls_status, sni,
                       dns_name, dns_other_names,
                       tls_version, tls_cipher_suite, tls_hello_retry, tls_alert
                FROM flows
                WHERE id = ?
                """,
                arguments: [id]
            )
            return try row.map(Serialization.storedFlow(from:))
        }
    }

    /// Los flujos etiquetados con una sesión de auditoría, del primero que empezó al último.
    ///
    /// El orden es el contrario al de `recentFlows` a propósito: la Timeline se lee de ahora hacia
    /// atrás, y una evidencia se lee como ocurrió — qué conexión fue antes del consentimiento es una
    /// pregunta sobre el principio.
    public func flows(inAuditSession id: Int64, limit: Int) throws -> [StoredFlow] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, proto, addr_a, port_a, addr_b, port_b,
                       first_seen, last_seen, bytes_out, bytes_in, packet_count, tls_status, sni,
                       dns_name, dns_other_names,
                       tls_version, tls_cipher_suite, tls_hello_retry, tls_alert
                FROM flows
                WHERE audit_session_id = ?
                ORDER BY first_seen ASC, id ASC
                LIMIT ?
                """,
                arguments: [id, limit]
            )
            return try rows.map(Serialization.storedFlow(from:))
        }
    }

    /// Cuántos flujos lleva una sesión de auditoría. Es la cifra que su pantalla enseña mientras
    /// graba: sin ella no hay forma de ver que el etiquetado está pasando.
    public func flowCount(inAuditSession id: Int64) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM flows WHERE audit_session_id = ?", arguments: [id]
            ) ?? 0
        }
    }

    /// Los ficheros de captura que guardan bytes de una sesión de auditoría.
    ///
    /// Los ficheros no llevan la sesión escrita en ningún sitio: se **deriva** de los paquetes de sus
    /// flujos, que ya dicen en qué fichero están. Una segunda marca en el nombre o en una tabla sería
    /// el mismo hecho dicho dos veces, y un `.pcap` rota por tamaño, no por sesión, así que uno solo
    /// puede llevar tráfico de dentro y de fuera.
    public func captureFileSequences(inAuditSession id: Int64) throws -> Set<UInt32> {
        try dbPool.read { db in
            try Self.fileSequences(
                from: Int64.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT p.pcap_file
                    FROM packets p
                    JOIN flows f ON f.id = p.flow_id
                    WHERE f.audit_session_id = ? AND p.pcap_offset != 0
                    """,
                    arguments: [id]
                )
            )
        }
    }

    /// Los ficheros de captura que guardan bytes de **alguna** sesión de auditoría: los que la
    /// retención no puede borrar.
    ///
    /// Es una consulta propia y no la unión de `captureFileSequences(inAuditSession:)` sesión a
    /// sesión porque quien la hace es el barrido —también el de la extensión, al rotar— y lo que
    /// necesita es una sola respuesta tomada en un solo instante: entre dos consultas puede abrirse
    /// una sesión, y su fichero quedaría fuera de la lista justo cuando se decide a quién borrar.
    public func auditEvidenceFileSequences() throws -> Set<UInt32> {
        try dbPool.read { db in
            try Self.fileSequences(
                from: Int64.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT p.pcap_file
                    FROM packets p
                    JOIN flows f ON f.id = p.flow_id
                    WHERE f.audit_session_id IS NOT NULL AND p.pcap_offset != 0
                    """
                )
            )
        }
    }

    private static func fileSequences(from values: [Int64]) throws -> Set<UInt32> {
        var sequences: Set<UInt32> = []
        for value in values {
            guard let sequence = UInt32(exactly: value) else {
                throw StoreError.corruptRow("pcap_file fuera de rango: \(value)")
            }
            sequences.insert(sequence)
        }
        return sequences
    }

    /// Mayor secuencia de fichero de captura que el historial referencia, o `nil` si ningún paquete
    /// guardado tiene bytes asociados.
    ///
    /// La consulta el escritor de capturas al arrancar: un fichero borrado desaparece del directorio
    /// pero sus paquetes siguen aquí apuntándolo, así que la secuencia que quede libre en disco
    /// puede no estarlo en el historial. Reutilizarla haría que esas filas señalasen los bytes de
    /// otra conexión.
    public func highestCaptureFileSequence() throws -> UInt32? {
        try dbPool.read { db in
            // `pcap_offset = 0` es "sin captura": esas filas no referencian ningún fichero, y su
            // columna `pcap_file` vale 0 sin significar nada.
            guard let highest = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(pcap_file) FROM packets WHERE pcap_offset != 0"
            ) else {
                return nil
            }
            guard let sequence = UInt32(exactly: highest) else {
                throw StoreError.corruptRow("pcap_file fuera de rango: \(highest)")
            }
            return sequence
        }
    }

    /// Trozos de contenido descifrado de un flujo, en orden temporal ascendente.
    ///
    /// Es lo que alimenta la mitad descifrada del Flow Inspector: la conversación, en el orden en que
    /// ocurrió y con su sentido. Los bytes se leen después, del fichero que cada fila señala.
    public func plaintext(forFlow id: Int64, limit: Int) throws -> [StoredPlaintextChunk] {
        try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, ts, direction, stream, file_seq, record_offset, stored_length, original_length
                FROM plaintext
                WHERE flow_id = ?
                ORDER BY ts ASC, id ASC
                LIMIT ?
                """,
                arguments: [id, limit]
            )
            return try rows.map(Serialization.storedPlaintextChunk(from:))
        }
    }

    /// Mayor secuencia de fichero de contenido descifrado que el índice referencia, o `nil` si no hay
    /// ninguna fila. La consulta el escritor al arrancar, por lo mismo que la de capturas: un fichero
    /// borrado desaparece del directorio pero sus filas siguen aquí apuntándolo.
    public func highestPlaintextFileSequence() throws -> UInt32? {
        try dbPool.read { db in
            guard let highest = try Int64.fetchOne(db, sql: "SELECT MAX(file_seq) FROM plaintext") else {
                return nil
            }
            guard let sequence = UInt32(exactly: highest) else {
                throw StoreError.corruptRow("file_seq fuera de rango: \(highest)")
            }
            return sequence
        }
    }

    /// Mayor identificador de conversación que el índice referencia, o `nil` si no hay ninguna fila.
    ///
    /// El escritor arranca por encima: si los identificadores volvieran a empezar en cada sesión, una
    /// fila de ayer validaría contra el registro de otra conversación de hoy.
    public func highestPlaintextStream() throws -> UInt64? {
        try dbPool.read { db in
            guard let highest = try Int64.fetchOne(db, sql: "SELECT MAX(stream) FROM plaintext") else {
                return nil
            }
            return Serialization.uint64(highest)
        }
    }

    /// Secuencias de fichero que el índice **todavía** referencia.
    ///
    /// Es lo que separa un fichero de contenido descifrado que aún sirve de uno huérfano: al caducar
    /// las filas por antigüedad (ADR 0007), los ficheros que ya no aparecen aquí no los va a abrir
    /// nadie nunca más y son exactamente lo que hay que borrar. Se pregunta **después** de podar.
    public func referencedPlaintextFileSequences() throws -> Set<UInt32> {
        try dbPool.read { db in
            let values = try Int64.fetchAll(db, sql: "SELECT DISTINCT file_seq FROM plaintext")
            var sequences: Set<UInt32> = []
            for value in values {
                guard let sequence = UInt32(exactly: value) else {
                    throw StoreError.corruptRow("file_seq fuera de rango: \(value)")
                }
                sequences.insert(sequence)
            }
            return sequences
        }
    }

    /// Cuántos trozos de contenido descifrado hay indexados. Es lo que permite decir si hay algo que
    /// borrar **antes** de ofrecer el gesto, y contarlo después.
    public func plaintextChunkCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM plaintext") ?? 0
        }
    }

    /// Instantes del paquete más antiguo y del más nuevo guardados, o `nil` si no hay ninguno.
    ///
    /// Es la extensión temporal del historial, que es lo que abarca el eje de la barra de scrub. Se
    /// mide sobre `packets` y no sobre `flows` porque lo que el eje cuenta son paquetes: un flujo
    /// vivo durante horas se solapa con muchos intervalos y decidir a cuál pertenece obligaría a
    /// mirar cada fila contra cada barra, mientras que un paquete cae en uno y solo uno.
    public func packetTimeBounds() throws -> ClosedRange<Date>? {
        try dbPool.read { db -> ClosedRange<Date>? in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT MIN(ts) AS oldest, MAX(ts) AS newest FROM packets"
            ) else {
                return nil
            }
            // Con la tabla vacía la fila existe igual, con ambos agregados a NULL.
            guard let oldest = row["oldest"] as Int64?, let newest = row["newest"] as Int64? else {
                return nil
            }
            guard oldest <= newest else {
                throw StoreError.corruptRow("MIN(ts) > MAX(ts): \(oldest) > \(newest)")
            }
            let first = WallClock.date(fromNanosecondsSince1970: oldest)
            let last = WallClock.date(fromNanosecondsSince1970: newest)
            return first...last
        }
    }

    /// Cuántos paquetes hay en cada intervalo de `range`, de más antiguo a más nuevo y **solo** los
    /// intervalos que tienen alguno.
    ///
    /// Es la consulta que alimenta el eje temporal de la Timeline, y es distinta de la paginación por
    /// cursor que usa la lista: una agregación acotada por el rango, no una ventana de filas.
    ///
    /// Los intervalos se alinean con el **principio del rango**, no con el epoch. Así la resta
    /// `ts - inicio` nunca es negativa y la división entera de SQLite (que trunca hacia cero, no hacia
    /// abajo) coincide con el suelo para todas las filas que entran; alinear al epoch metería un error
    /// de un intervalo en cualquier sello anterior a 1970, que solo puede venir de un reloj corrupto
    /// pero saldría dibujado igual. Lo que el usuario lee de una barra es su intervalo real, así que
    /// la alineación no le miente.
    ///
    /// **No filtra nada más.** Las cuentas son de todo lo guardado, incluidos los paquetes de
    /// conexiones que el filtro de la pantalla esconde: el filtro de host se aplica en memoria sobre
    /// el host visible (`docs/spec/app-services.md`), así que honrar unos criterios y otros no dejaría
    /// un eje que parece filtrado sin serlo. Decirlo en pantalla es de la vista.
    public func packetCounts(
        in range: ClosedRange<Date>, bucketDuration: TimeInterval
    ) throws -> [PacketBucket] {
        let nanoseconds = (bucketDuration * 1_000_000_000).rounded()
        precondition(nanoseconds >= 1, "el intervalo no puede ser menor que un nanosegundo")
        precondition(nanoseconds <= Double(Int64.max), "intervalo fuera del rango representable")
        let bucketNanoseconds = Int64(nanoseconds)

        let start = WallClock.nanosecondsSince1970(from: range.lowerBound)
        let end = WallClock.nanosecondsSince1970(from: range.upperBound)

        return try dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT (ts - ?) / ? AS bucket, COUNT(*) AS packets
                FROM packets
                WHERE ts >= ? AND ts <= ?
                GROUP BY bucket
                ORDER BY bucket ASC
                """,
                arguments: [start, bucketNanoseconds, start, end]
            )
            return try rows.map { row in
                let index = row["bucket"] as Int64
                // El índice sale de una división de valores guardados: un `ts` corrupto (muy por
                // delante del reloj) lo dispararía, y volver a multiplicarlo desbordaría en vez de
                // dar una fecha. Se reporta como fila corrupta, que es lo que es.
                let (offset, offsetOverflowed) = index.multipliedReportingOverflow(by: bucketNanoseconds)
                let (origin, originOverflowed) = start.addingReportingOverflow(offset)
                guard !offsetOverflowed, !originOverflowed else {
                    throw StoreError.corruptRow("índice de intervalo fuera de rango: \(index)")
                }
                return PacketBucket(
                    start: WallClock.date(fromNanosecondsSince1970: origin),
                    packetCount: row["packets"]
                )
            }
        }
    }

    // MARK: - Mantenimiento

    /// Borra los flujos cuyo `last_seen` es anterior al corte; el `ON DELETE CASCADE` elimina
    /// también sus paquetes. Devuelve el número de flujos borrados. Aplica el tope de retención que
    /// la app expone en Ajustes → Almacenamiento, que es por **antigüedad real**: por eso el corte es
    /// una fecha y no un sello monotónico, que no sobreviviría a un reinicio del dispositivo.
    ///
    /// **Los flujos de una sesión de auditoría no caducan**: son evidencia, y con el tope de fábrica
    /// de una semana se irían antes de que nadie los exportara. Se quedan hasta que se borre su
    /// sesión o su proyecto, que es lo que les quita la etiqueta (`docs/spec/audit.md`).
    @discardableResult
    public func prune(before cutoff: Date) throws -> Int {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM flows WHERE last_seen < ? AND audit_session_id IS NULL",
                arguments: [WallClock.nanosecondsSince1970(from: cutoff)]
            )
            return db.changesCount
        }
    }

    /// Borra el contenido descifrado anterior al corte **sin tocar los flujos ni sus paquetes**.
    /// Devuelve cuántos trozos se fueron.
    ///
    /// Es una poda propia y no un caso de `prune(before:)` porque el contenido descifrado caduca
    /// **antes** que el historial que lo contiene (ADR 0007): un flujo de hace tres días sigue en la
    /// Timeline con sus bytes contados mientras que lo que dijo por dentro ya no está. Por eso el
    /// corte es otro y el borrado también.
    ///
    /// Los ficheros no se tocan aquí: los borra quien ejecuta el barrido, que es el único que sabe
    /// mirar el directorio. Lo que le dice cuáles sobran es `referencedPlaintextFileSequences()`
    /// después de esto.
    @discardableResult
    public func prunePlaintext(before cutoff: Date) throws -> Int {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM plaintext WHERE ts < ?",
                arguments: [WallClock.nanosecondsSince1970(from: cutoff)]
            )
            return db.changesCount
        }
    }

    /// Borra las filas que apuntan a unos ficheros concretos de contenido descifrado. Devuelve
    /// cuántas se fueron.
    ///
    /// Es la mitad de índice del **techo de disco**: la antigüedad borra filas y deja ficheros
    /// huérfanos, pero el techo va al revés —se lleva ficheros enteros, los más antiguos, para caber—
    /// y las filas que los nombraban tienen que irse con ellos. Dejarlas sería peor que no tenerlas:
    /// contarían como contenido guardado (`plaintextChunkCount`) sin haber ya bytes que leer, y la
    /// pantalla de una conexión ofrecería abrir lo que no está.
    ///
    /// Se llama **después** de borrar los ficheros y solo con los que se borraron de verdad: un
    /// fichero que no se dejó borrar sigue siendo legible, y perder su índice lo convertiría en
    /// espacio ocupado que ya nadie sabe barrer.
    @discardableResult
    public func prunePlaintext(inFileSequences sequences: [UInt32]) throws -> Int {
        guard !sequences.isEmpty else { return 0 }
        return try dbPool.write { db in
            let placeholders = databaseQuestionMarks(count: sequences.count)
            try db.execute(
                sql: "DELETE FROM plaintext WHERE file_seq IN (\(placeholders))",
                arguments: StatementArguments(sequences.map { Int64($0) })
            )
            return db.changesCount
        }
    }

    /// Borra **todo** el contenido descifrado indexado, dejando intactos el historial y las capturas.
    /// Devuelve cuántos trozos se fueron.
    ///
    /// Es el gesto que el ADR 0007 pide que exista por separado: quien se arrepiente de haber grabado
    /// lo que descifró no debería tener que tirar además su historial entero para deshacerlo.
    @discardableResult
    public func clearPlaintext() throws -> Int {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM plaintext")
            return db.changesCount
        }
    }

    /// Cuántas conexiones hay guardadas. Es lo que Ajustes → Almacenamiento enseña junto a los bytes,
    /// porque un tamaño de BD no significa nada para el usuario y un número de conexiones sí, y lo que
    /// `clearAll` se va a llevar solo se puede contar **antes** de vaciar.
    public func flowCount() throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM flows") ?? 0
        }
    }

    /// Bytes que ocupa la BD en disco, incluidos los ficheros auxiliares de WAL (`-wal`/`-shm`).
    public func totalBytesOnDisk() throws -> Int64 {
        let manager = FileManager.default
        let paths = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
        var total: Int64 = 0
        for path in paths {
            // Los sidecars de WAL pueden no existir; su ausencia no es un error.
            guard let size = try? manager.attributesOfItem(atPath: path)[.size] as? Int64 else {
                continue
            }
            total += size
        }
        return total
    }

    /// Vacía por completo el historial. El cascade borra los paquetes al borrar los flujos.
    public func clearAll() throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM flows")
        }
    }
}

/// Conversión entre tipos de dominio y columnas SQLite. Aislada aquí para que el layout on-disk
/// tenga un único punto de verdad junto al `Schema`.
private enum Serialization {

    /// Los enteros sin signo del dominio (contadores de bytes, offsets del pcap) se guardan
    /// reinterpretando sus bits como `Int64`, que es el entero nativo de SQLite. El round-trip es
    /// exacto y el orden se preserva para los valores del dominio (siempre < Int64.max).
    static func int64(_ value: UInt64) -> Int64 { Int64(bitPattern: value) }

    static func uint64(_ value: Int64) -> UInt64 { UInt64(bitPattern: value) }

    static func ipAddress(from data: Data) throws -> IPAddress {
        switch data.count {
        case 4: return IPAddress(version: .v4, bytes: [UInt8](data))
        case 16: return IPAddress(version: .v6, bytes: [UInt8](data))
        default:
            throw FlowStore.StoreError.corruptRow("blob de dirección con \(data.count) bytes (esperados 4 o 16)")
        }
    }

    static func proto(from raw: Int) throws -> IPProtocolNumber {
        guard let value = UInt8(exactly: raw), let proto = IPProtocolNumber(rawValue: value) else {
            throw FlowStore.StoreError.corruptRow("valor de protocolo inválido: \(raw)")
        }
        return proto
    }

    static func tlsStatus(from raw: Int) throws -> TLSInspectionStatus {
        guard let value = UInt8(exactly: raw), let status = TLSInspectionStatus(rawValue: value) else {
            throw FlowStore.StoreError.corruptRow("valor de tls_status inválido: \(raw)")
        }
        return status
    }

    static func direction(from raw: Int) throws -> Direction {
        guard let value = UInt8(exactly: raw), let direction = Direction(rawValue: value) else {
            throw FlowStore.StoreError.corruptRow("valor de dirección inválido: \(raw)")
        }
        return direction
    }

    static func port(from raw: Int) throws -> UInt16 {
        guard let value = UInt16(exactly: raw) else {
            throw FlowStore.StoreError.corruptRow("puerto fuera de rango: \(raw)")
        }
        return value
    }

    /// Reconstruye la `FlowKey` canónica desde las columnas `proto`/`addr_*`/`port_*`. Los
    /// endpoints ya están en orden canónico en disco; pasarlos como (source, destination)
    /// reproduce la misma clave.
    static func flowKey(from row: Row) throws -> FlowKey {
        let addrA = try ipAddress(from: row["addr_a"])
        let addrB = try ipAddress(from: row["addr_b"])
        let endpointA = IPEndpoint(address: addrA, port: try port(from: row["port_a"]))
        let endpointB = IPEndpoint(address: addrB, port: try port(from: row["port_b"]))
        return FlowKey(proto: try proto(from: row["proto"]), source: endpointA, destination: endpointB)
    }

    static func storedFlow(from row: Row) throws -> StoredFlow {
        StoredFlow(
            id: row["id"],
            key: try flowKey(from: row),
            firstSeen: WallClock.date(fromNanosecondsSince1970: row["first_seen"]),
            lastSeen: WallClock.date(fromNanosecondsSince1970: row["last_seen"]),
            bytesOut: uint64(row["bytes_out"]),
            bytesIn: uint64(row["bytes_in"]),
            packetCount: uint64(row["packet_count"]),
            tlsStatus: try tlsStatus(from: row["tls_status"]),
            sni: row["sni"],
            resolvedName: resolvedName(name: row["dns_name"], otherNames: row["dns_other_names"]),
            serverTLS: try serverTLS(
                version: row["tls_version"],
                cipherSuite: row["tls_cipher_suite"],
                helloRetry: row["tls_hello_retry"],
                alert: row["tls_alert"]
            )
        )
    }

    /// Las cuatro columnas de la respuesta TLS del servidor, tal y como van a la fila.
    struct ServerTLSColumns {
        let version: Int?
        let cipherSuite: Int?
        let helloRetry: Bool?
        let alert: Int?
    }

    static func serverTLSColumns(_ answer: ServerTLSAnswer?) -> ServerTLSColumns {
        switch answer {
        case .negotiated(let negotiated):
            return ServerTLSColumns(
                version: Int(negotiated.version.rawValue),
                cipherSuite: Int(negotiated.cipherSuite.rawValue),
                helloRetry: negotiated.fromHelloRetryRequest,
                alert: nil
            )
        case .refused(let alert):
            return ServerTLSColumns(version: nil, cipherSuite: nil, helloRetry: nil, alert: Int(alert))
        case nil:
            return ServerTLSColumns(version: nil, cipherSuite: nil, helloRetry: nil, alert: nil)
        }
    }

    /// La alerta manda si está: excluye a las otras tres. Una versión sin suite —o al revés— no la
    /// escribe este store, así que es una fila corrupta y se dice en vez de inventar la mitad que
    /// falta.
    static func serverTLS(
        version: Int?,
        cipherSuite: Int?,
        helloRetry: Bool?,
        alert: Int?
    ) throws -> ServerTLSAnswer? {
        if let alert {
            guard let code = UInt8(exactly: alert) else {
                throw FlowStore.StoreError.corruptRow("alerta de TLS fuera de rango: \(alert)")
            }
            return .refused(alert: code)
        }
        switch (version, cipherSuite) {
        case (nil, nil):
            return nil
        case (let version?, let cipherSuite?):
            guard let versionCode = UInt16(exactly: version), let suiteCode = UInt16(exactly: cipherSuite) else {
                throw FlowStore.StoreError.corruptRow("versión o suite de TLS fuera de rango: \(version), \(cipherSuite)")
            }
            return .negotiated(NegotiatedTLS(
                version: TLSProtocolVersion(rawValue: versionCode),
                cipherSuite: TLSCipherSuite(rawValue: suiteCode),
                fromHelloRetryRequest: helloRetry ?? false
            ))
        case (.some, nil), (nil, .some):
            throw FlowStore.StoreError.corruptRow("versión y suite de TLS desparejadas")
        }
    }

    /// Separador de `dns_other_names`. Un nombre del mapa no puede contenerlo (`DomainPattern`).
    private static let otherNamesSeparator: Character = " "

    /// La lista de otros candidatos como texto de columna; vacía es `NULL`.
    static func otherNames(_ names: [String]) -> String? {
        names.isEmpty ? nil : names.joined(separator: String(otherNamesSeparator))
    }

    /// Sin `dns_name` no hay nombre resuelto, diga lo que diga la otra columna: los candidatos lo
    /// son *de* un nombre.
    static func resolvedName(name: String?, otherNames: String?) -> ResolvedFlowName? {
        guard let name else { return nil }
        return ResolvedFlowName(
            name: name,
            otherNames: otherNames?.split(separator: otherNamesSeparator).map(String.init) ?? []
        )
    }

    static func storedPacket(from row: Row) throws -> StoredPacket {
        guard let length = UInt32(exactly: row["length"] as Int) else {
            throw FlowStore.StoreError.corruptRow("length fuera de rango: \(row["length"] as Int)")
        }
        guard let flags = UInt8(exactly: row["tcp_flags"] as Int) else {
            throw FlowStore.StoreError.corruptRow("tcp_flags fuera de rango: \(row["tcp_flags"] as Int)")
        }
        return StoredPacket(
            id: row["id"],
            date: WallClock.date(fromNanosecondsSince1970: row["ts"]),
            flowKey: try flowKey(from: row),
            direction: try direction(from: row["direction"]),
            length: length,
            tcpFlags: TCPFlags(rawValue: flags),
            capture: try captureLocation(from: row)
        )
    }

    static func storedPlaintextChunk(from row: Row) throws -> StoredPlaintextChunk {
        let stored = row["stored_length"] as Int64
        let original = row["original_length"] as Int64
        guard let storedLength = UInt32(exactly: stored), let originalLength = UInt32(exactly: original) else {
            throw FlowStore.StoreError.corruptRow("longitudes de plaintext fuera de rango: \(stored)/\(original)")
        }
        guard let fileSequence = UInt32(exactly: row["file_seq"] as Int64) else {
            throw FlowStore.StoreError.corruptRow("file_seq fuera de rango: \(row["file_seq"] as Int64)")
        }
        return StoredPlaintextChunk(
            id: row["id"],
            date: WallClock.date(fromNanosecondsSince1970: row["ts"]),
            direction: try direction(from: row["direction"]),
            stream: uint64(row["stream"]),
            location: PlaintextLocation(
                fileSequence: fileSequence,
                recordOffset: uint64(row["record_offset"])
            ),
            storedLength: storedLength,
            originalLength: originalLength
        )
    }

    /// Reconstruye la pareja (fichero, offset) o `nil` si el paquete no se capturó. El centinela es
    /// el offset: 0 no puede ser un registro, porque todo `.pcap` empieza por su cabecera global.
    static func captureLocation(from row: Row) throws -> CaptureLocation? {
        let recordOffset = uint64(row["pcap_offset"])
        guard recordOffset != 0 else { return nil }
        guard let fileSequence = UInt32(exactly: row["pcap_file"] as Int64) else {
            throw FlowStore.StoreError.corruptRow("pcap_file fuera de rango: \(row["pcap_file"] as Int64)")
        }
        return CaptureLocation(fileSequence: fileSequence, recordOffset: recordOffset)
    }
}
