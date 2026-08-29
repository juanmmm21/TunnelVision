import Foundation

// Debug-only por lo mismo que el generador de al lado: una captura sintética **escrita** en el
// contenedor compartido es indistinguible de una real —el historial no marca de dónde salió una
// fila—, y aquí es donde deja de ser un valor en memoria y pasa a ser el historial que la app enseña.
#if DEBUG

/// Qué se escribió, para poder contarlo por consola.
///
/// Existe porque sembrar no es instantáneo (la captura por defecto son miles de paquetes y varios
/// megabytes de `.pcap`): sin un resumen al terminar, el primero que lance la app con el argumento
/// creería que se ha colgado. Va en tipos y no en una cadena suelta para que el test afirme los
/// números y no cómo se redactan.
public struct SeedReport: Sendable, Equatable {

    public let flowCount: Int
    public let packetCount: Int

    /// Cuántos de esos paquetes tienen sus bytes en un `.pcap`. El resto reproducen lo que en
    /// producción deja un fallo de escritura o la captura apagada: metadato sí, bytes no.
    public let capturedPacketCount: Int

    /// Secuencias de los ficheros escritos, en orden. Son las que llevan guardadas las
    /// `CaptureLocation` de los paquetes de dentro.
    public let captureFileSequences: [UInt32]

    public let captureBytes: UInt64

    /// Trozos de contenido descifrado escritos e indexados. Cero cuando ningún flujo se inspeccionó.
    public let plaintextChunkCount: Int

    /// Bytes que ocupa el directorio de contenido descifrado al terminar.
    public let plaintextBytes: UInt64

    /// Hora de pared del primer y del último paquete: lo que el eje de la Timeline abarcará.
    public let span: ClosedRange<Date>?

    /// Lo que había antes y se ha ido. Sembrar **reemplaza**, así que decir solo lo que se escribe
    /// contaría media historia.
    public let replacedFlowCount: Int
    public let replacedCaptureFileCount: Int

    public init(
        flowCount: Int,
        packetCount: Int,
        capturedPacketCount: Int,
        captureFileSequences: [UInt32],
        captureBytes: UInt64,
        plaintextChunkCount: Int,
        plaintextBytes: UInt64,
        span: ClosedRange<Date>?,
        replacedFlowCount: Int,
        replacedCaptureFileCount: Int
    ) {
        self.flowCount = flowCount
        self.packetCount = packetCount
        self.capturedPacketCount = capturedPacketCount
        self.captureFileSequences = captureFileSequences
        self.captureBytes = captureBytes
        self.plaintextChunkCount = plaintextChunkCount
        self.plaintextBytes = plaintextBytes
        self.span = span
        self.replacedFlowCount = replacedFlowCount
        self.replacedCaptureFileCount = replacedCaptureFileCount
    }

    /// La línea que se imprime por consola. **No es copia de producto**: es un diagnóstico para quien
    /// lanza la app desde Xcode o desde `xcrun simctl`, así que no pasa por el catálogo (la misma
    /// regla que el identificador de App Group y el número de secuencia de la pantalla de capturas) y
    /// se formatea con `en_US_POSIX`, que es lo correcto cuando quien lee es una persona mirando una
    /// consola y no la UI de la app.
    public var summary: String {
        let dates = span.map { " covering \(Self.stamp($0.lowerBound)) – \(Self.stamp($0.upperBound))" } ?? ""
        let replaced = replacedFlowCount == 0 && replacedCaptureFileCount == 0
            ? ""
            : " (replacing \(replacedFlowCount) connections and \(replacedCaptureFileCount) capture files)"
        let decrypted = plaintextChunkCount == 0
            ? ""
            : " Plus \(plaintextChunkCount) decrypted pieces of \(plaintextBytes) bytes."
        return """
            Seeded \(flowCount) connections and \(packetCount) packets \
            (\(capturedPacketCount) with bytes) into \(captureFileSequences.count) capture files \
            of \(captureBytes) bytes\(dates)\(replaced).\(decrypted)
            """
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date) + "Z"
    }
}

public enum SeedError: Error, Sendable, Equatable {
    /// El contenedor del App Group no se pudo resolver. No es "no hay nada sembrado": es que no se
    /// sabe dónde escribir.
    case appGroupUnavailable
    /// El directorio de capturas no se pudo preparar (crear, o vaciar lo que ya había).
    case captureDirectoryUnusable(String)
    /// El de contenido descifrado tampoco. Va aparte del de capturas porque son dos directorios con
    /// dos retenciones distintas, y un mensaje que no dijese cuál de los dos no sirve de nada.
    case plaintextDirectoryUnusable(String)
    /// El fichero se escribió pero no se le pudo poner su nombre o su fecha definitivos. Se propaga
    /// en vez de tragarse porque la pantalla de capturas lee esa fecha del sistema de ficheros: un
    /// fichero dejado con la de "ahora" enseñaría un historial de seis horas en ficheros que dicen
    /// haberse abierto hace un segundo.
    case captureFileNotFinalised(String)
}

/// Escribe una `CaptureFixture` donde la app la lee: el historial (`FlowStore`) y el directorio de
/// capturas (`PcapWriter`).
///
/// Es la otra mitad del sembrador. El generador de al lado produce la captura sin tocar disco; esto
/// la deja escrita, que es lo único que hace que las pantallas densas existan en Simulator — donde la
/// extensión, que es la única que escribe historial y capturas, no corre.
///
/// **No alimenta el feed en vivo**, y es una decisión y no un olvido: el ring es memoria compartida
/// con un contrato SPSC de un solo productor, que es la extensión, y escribir por ese lado desde la
/// app sería romper el contrato para dibujar un gráfico. La Dashboard sigue plana en Simulator; lo
/// que se llena es su historial.
///
/// **Reemplaza, no acumula.** Sembrar dos veces deja la misma captura y no dos, que es lo que hace
/// que el argumento de lanzamiento se pueda repetir y —lo que de verdad importa— que dos mediciones
/// con la misma semilla midan el mismo trabajo. Acumular convertiría la reproducibilidad del
/// generador, que es su razón de ser, en una promesa que el disco desmiente.
public struct FixtureSeeder: Sendable {

    public struct Configuration: Sendable, Equatable {

        /// En cuántos ficheros se reparte la captura. Se fija un **número de ficheros** y no un tope
        /// de bytes porque lo que hay que garantizar es el estado de pantalla: con un solo fichero, la
        /// lista de capturas es una fila y no enseña ni el total del pie ni el borrado de uno entre
        /// varios. Un tope en bytes daría un número distinto por cada especificación —una propiedad
        /// que depende de los datos no se puede afirmar—, y el sembrador conoce la captura entera de
        /// antemano, así que puede rotar donde quiera. Es el mismo criterio con el que el generador
        /// fuerza sus tramos vacíos en vez de esperar a que salgan.
        public var captureFileCount: Int

        /// Cuánto de cada paquete llega al fichero. Se expresa en el vocabulario del producto y no en
        /// un `snaplen` suelto para que sea el mismo ajuste que la pantalla de Ajustes edita.
        public var captureDetail: CaptureDetail

        public init(captureFileCount: Int = 3, captureDetail: CaptureDetail = .fullPayload) {
            precondition(captureFileCount >= 1, "una captura vive al menos en un fichero")
            self.captureFileCount = captureFileCount
            self.captureDetail = captureDetail
        }
    }

    private let databaseURL: URL
    private let captureDirectory: URL
    private let plaintextDirectory: URL
    private let configuration: Configuration

    /// Sobre rutas concretas. Es lo que usan los tests, sobre un temporal.
    public init(
        databaseURL: URL,
        captureDirectory: URL,
        plaintextDirectory: URL,
        configuration: Configuration = Configuration()
    ) {
        self.databaseURL = databaseURL
        self.captureDirectory = captureDirectory
        self.plaintextDirectory = plaintextDirectory
        self.configuration = configuration
    }

    /// Sobre el contenedor compartido: exactamente los mismos sitios que escribe la extensión y lee la
    /// app, resueltos por los mismos tipos (`FlowStore`, `CaptureDirectory`).
    public init(appGroupID: String, configuration: Configuration = Configuration()) throws {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
              let captures = CaptureDirectory.url(inAppGroup: appGroupID),
              let plaintext = PlaintextDirectory.url(inAppGroup: appGroupID)
        else {
            throw SeedError.appGroupUnavailable
        }
        self.init(
            databaseURL: container.appendingPathComponent("TunnelVision.sqlite"),
            captureDirectory: captures,
            plaintextDirectory: plaintext,
            configuration: configuration
        )
    }

    /// Escribe la captura y devuelve lo que dejó.
    ///
    /// El orden —vaciar, escribir los `.pcap`, escribir el historial— no es libre. Los ficheros van
    /// **antes** que las filas por lo mismo que en `StorageManager`: el modo de fallar de ese orden
    /// (filas que apuntan a bytes que no están) es uno que la app ya sabe explicar, mientras que el
    /// contrario deja ficheros que nadie referencia. Y el historial va **después** de la captura
    /// porque cada paquete guarda dónde quedaron sus bytes, que es lo único que no se sabe hasta que
    /// están escritos.
    public func seed(_ fixture: CaptureFixture) async throws -> SeedReport {
        // El store se abre con el ancla **de la captura**, no con la de ahora: los sellos de los
        // paquetes son del reloj monotónico y solo significan algo junto a ella. Con `.now()` el
        // historial quedaría fechado seis horas en el futuro.
        let store = try FlowStore(databaseURL: databaseURL, anchor: fixture.anchor)

        let replacedFlowCount = try await store.flowCount()
        let replacedCaptureFileCount = try prepareCaptureDirectory()
        try preparePlaintextDirectory()
        try await store.clearAll()

        let written = try await writeCapture(fixture)
        // El contenido descifrado va **después** de la captura y **antes** del historial, por lo
        // mismo que ella: sus filas guardan dónde quedaron sus bytes, que es lo único que no se sabe
        // hasta que están escritos, y las dos mitades entran en la misma pasada por los flujos.
        let decrypted = try await writePlaintext(fixture)
        try await writeHistory(
            fixture, locations: written.locations, plaintext: decrypted, into: store
        )

        return SeedReport(
            flowCount: fixture.flows.count,
            packetCount: fixture.packetCount,
            capturedPacketCount: fixture.capturedPacketCount,
            captureFileSequences: written.sequences,
            captureBytes: captureDirectoryBytes(),
            plaintextChunkCount: decrypted.reduce(0) { $0 + $1.count },
            plaintextBytes: plaintextDirectoryBytes(),
            span: fixture.wallClockSpan,
            replacedFlowCount: replacedFlowCount,
            replacedCaptureFileCount: replacedCaptureFileCount
        )
    }

    // MARK: - El directorio

    /// Deja el directorio creado y vacío de capturas nuestras, y devuelve cuántas se llevó por
    /// delante. Solo borra ficheros que `CaptureFileName` reconozca: el directorio es compartido y
    /// llevarse lo que no es nuestro sería pasarse del encargo.
    private func prepareCaptureDirectory() throws -> Int {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        } catch {
            throw SeedError.captureDirectoryUnusable(error.localizedDescription)
        }

        let existing = CaptureDirectory.files(in: captureDirectory)
        for file in existing {
            do {
                try manager.removeItem(at: file.url)
            } catch {
                throw SeedError.captureDirectoryUnusable(error.localizedDescription)
            }
        }
        return existing.count
    }

    /// Lo mismo para el contenido descifrado, y **por separado**: son dos directorios con dos
    /// retenciones distintas (ADR 0007), así que vaciar uno no puede llevarse el otro por delante.
    private func preparePlaintextDirectory() throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: plaintextDirectory, withIntermediateDirectories: true)
            for file in PlaintextDirectory.files(in: plaintextDirectory) {
                try manager.removeItem(at: file.url)
            }
        } catch {
            throw SeedError.plaintextDirectoryUnusable(error.localizedDescription)
        }
    }

    private func plaintextDirectoryBytes() -> UInt64 {
        PlaintextDirectory.files(in: plaintextDirectory).reduce(into: UInt64(0)) { total, file in
            guard let size = try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            total += UInt64(size)
        }
    }

    private func captureDirectoryBytes() -> UInt64 {
        CaptureDirectory.files(in: captureDirectory).reduce(into: UInt64(0)) { total, file in
            guard let size = try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return }
            total += UInt64(size)
        }
    }

    // MARK: - Los ficheros de captura

    /// Dónde quedó cada paquete, indexado igual que `fixture.flows[_].packets[_]`, y qué ficheros se
    /// escribieron.
    private struct WrittenCapture {
        let locations: [[CaptureLocation?]]
        let sequences: [UInt32]
    }

    /// Un paquete con bytes que escribir, situado en la captura: su sello (por el que se ordena) y
    /// dónde vive, para poder devolverle su `CaptureLocation` al sitio del que salió.
    private struct CapturedPacketRef {
        let timestamp: UInt64
        let flowIndex: Int
        let packetIndex: Int
    }

    private func writeCapture(_ fixture: CaptureFixture) async throws -> WrittenCapture {
        var locations = fixture.flows.map { flow in
            [CaptureLocation?](repeating: nil, count: flow.packets.count)
        }

        // Los paquetes se escriben en el orden en que ocurrieron, **cruzando los flujos**, porque eso
        // es lo que es una captura: un fichero por dispositivo y no uno por conexión. Escribirlos
        // flujo a flujo dejaría cada conexión en orden y el fichero entero yendo hacia atrás, que es
        // algo que ningún `.pcap` real hace y que Wireshark enseña como deltas negativos. El desempate
        // por índice mantiene el resultado determinista cuando dos sellos coinciden.
        let order = fixture.flows.enumerated()
            .flatMap { flowIndex, flow in
                flow.packets.enumerated().compactMap { packetIndex, packet -> CapturedPacketRef? in
                    guard packet.wasCaptured else { return nil }
                    return CapturedPacketRef(
                        timestamp: packet.timestamp,
                        flowIndex: flowIndex,
                        packetIndex: packetIndex
                    )
                }
            }
            .sorted {
                ($0.timestamp, $0.flowIndex, $0.packetIndex)
                    < ($1.timestamp, $1.flowIndex, $1.packetIndex)
            }

        guard !order.isEmpty else { return WrittenCapture(locations: locations, sequences: []) }

        let writer = try PcapWriter(
            config: PcapWriter.Config(
                directory: captureDirectory,
                snaplen: configuration.captureDetail.snaplen,
                // La rotación la decide el sembrador, no el tamaño: `maxFileBytes` se pone fuera de
                // alcance para que el writer no rote por su cuenta a mitad de un tramo elegido.
                maxFileBytes: .max,
                // Nada referencia ninguna secuencia: el historial se acaba de vaciar y el directorio
                // también, así que las secuencias arrancan en 0 y la captura sembrada es reproducible
                // también en los nombres de sus ficheros.
                highestReferencedSequence: nil
            )
        )

        let boundaries = Self.rotationBoundaries(
            packetCount: order.count,
            fileCount: configuration.captureFileCount
        )
        /// Sello del primer registro de cada fichero: con lo que se le pone después su nombre y su
        /// fecha, para que las tres cosas que un fichero dice de sí mismo digan lo mismo.
        var firstStampBySequence: [UInt32: UInt64] = [:]
        var sequences: [UInt32] = []

        for (position, reference) in order.enumerated() {
            if boundaries.contains(position) {
                try await writer.rotate()
            }
            let packet = fixture.flows[reference.flowIndex].packets[reference.packetIndex]
            // El sello del fixture es monotónico, como el del hot path; el `.pcap` fecha en absoluto,
            // así que se convierte con el ancla igual que lo hace el pipeline en el dispositivo. Sin
            // esto una captura sembrada se abre en Wireshark fechada en 1970.
            let location = try await writer.write(
                packet: packet.bytes,
                originalLength: packet.bytes.count,
                timestamp: fixture.anchor.nanosecondsSince1970(forUptime: packet.timestamp)
            )
            locations[reference.flowIndex][reference.packetIndex] = location

            if firstStampBySequence[location.fileSequence] == nil {
                firstStampBySequence[location.fileSequence] = packet.timestamp
                sequences.append(location.fileSequence)
            }
        }
        await writer.close()

        try finalise(firstStampBySequence, anchor: fixture.anchor)
        return WrittenCapture(locations: locations, sequences: sequences)
    }

    /// Posiciones (dentro de los paquetes capturados) delante de las cuales hay que rotar, para que la
    /// captura acabe repartida en `fileCount` ficheros de tamaño parecido. Nunca incluye la 0: rotar
    /// antes del primer paquete dejaría un fichero con solo su cabecera global, que es una captura
    /// vacía en la lista.
    static func rotationBoundaries(packetCount: Int, fileCount: Int) -> Set<Int> {
        let files = max(1, min(fileCount, packetCount))
        guard files > 1 else { return [] }
        return Set((1..<files).map { $0 * packetCount / files })
    }

    /// Le pone a cada fichero el nombre y la fecha de creación de su primer registro.
    ///
    /// No es cosmética. La pantalla de capturas lee la fecha del **sistema de ficheros** (el nombre no
    /// se parsea nunca) y el planificador de retención envejece un fichero por la de su sucesor, así
    /// que dejarlos todos en "ahora" enseñaría seis horas de historial en ficheros que dicen haberse
    /// abierto hace un segundo, y dejaría la retención sin nada que cortar sobre la única captura que
    /// se puede sembrar para probarla.
    private func finalise(_ firstStampBySequence: [UInt32: UInt64], anchor: MonotonicAnchor) throws {
        let manager = FileManager.default
        for file in CaptureDirectory.files(in: captureDirectory) {
            guard let stamp = firstStampBySequence[file.sequence] else { continue }
            let date = anchor.date(forUptime: stamp)
            let destination = captureDirectory.appendingPathComponent(
                CaptureFileName.make(sequence: file.sequence, date: date)
            )
            do {
                if destination != file.url {
                    try manager.moveItem(at: file.url, to: destination)
                }
                try manager.setAttributes([.creationDate: date], ofItemAtPath: destination.path)
            } catch {
                throw SeedError.captureFileNotFinalised(error.localizedDescription)
            }
        }
    }

    // MARK: - El contenido descifrado

    /// Un trozo situado en el fichero: el sello por el que se ordena y de qué flujo salió.
    private struct DecryptedChunkRef {
        let timestamp: UInt64
        let flowIndex: Int
        let chunkIndex: Int
    }

    /// Escribe los trozos descifrados y devuelve sus metadatos, indexados igual que
    /// `fixture.flows[_].plaintext[_]`.
    ///
    /// Se escriben **cruzando los flujos**, como los paquetes y por una razón más fuerte: un fichero
    /// `.tvpt` intercala conversaciones a propósito, y es justo lo que la `stream` de cada registro
    /// existe para desenredar. Escribirlos flujo a flujo dejaría un fixture donde esa propiedad no se
    /// ejercita nunca.
    ///
    /// El escritor es el **de verdad** y con su configuración de producción: el recorte del trozo que
    /// no cabe lo hace él contra su `maxRecordBytes`, que es lo que hace que el estado "esto no se
    /// guardó entero" del fixture sea el mismo que el de un dispositivo.
    private func writePlaintext(_ fixture: CaptureFixture) async throws -> [[PlaintextChunkMeta]] {
        var metas = fixture.flows.map { flow in
            [PlaintextChunkMeta?](repeating: nil, count: flow.plaintext.count)
        }

        let order = fixture.flows.enumerated()
            .flatMap { flowIndex, flow in
                flow.plaintext.enumerated().map { chunkIndex, chunk in
                    DecryptedChunkRef(
                        timestamp: chunk.timestamp, flowIndex: flowIndex, chunkIndex: chunkIndex
                    )
                }
            }
            .sorted {
                ($0.timestamp, $0.flowIndex, $0.chunkIndex)
                    < ($1.timestamp, $1.flowIndex, $1.chunkIndex)
            }

        guard !order.isEmpty else { return metas.map { $0.compactMap { $0 } } }

        let writer = PlaintextWriter(
            config: PlaintextWriter.Config(
                directory: plaintextDirectory,
                // Nada referencia ninguna secuencia ni ninguna conversación: la base se acaba de
                // vaciar y el directorio también, así que la siembra es reproducible también en los
                // nombres de sus ficheros.
                highestReferencedSequence: nil,
                highestReferencedStream: nil
            )
        )

        // Una conversación por flujo, repartida antes de escribir nada: es lo que empareja los
        // registros dispersos de un mismo flujo dentro de los ficheros.
        var streams: [Int: UInt64] = [:]
        for reference in order where streams[reference.flowIndex] == nil {
            streams[reference.flowIndex] = await writer.openStream()
        }

        for reference in order {
            let chunk = fixture.flows[reference.flowIndex].plaintext[reference.chunkIndex]
            guard let stream = streams[reference.flowIndex] else { continue }
            guard let location = try await writer.write(
                chunk.bytes,
                stream: stream,
                direction: chunk.direction,
                timestamp: fixture.anchor.nanosecondsSince1970(forUptime: chunk.timestamp)
            ) else {
                continue
            }
            metas[reference.flowIndex][reference.chunkIndex] = PlaintextChunkMeta(
                timestamp: chunk.timestamp,
                direction: chunk.direction,
                stream: stream,
                location: location,
                // Lo guardado lo decide el escritor contra su tope, así que se lee de vuelta en vez
                // de suponerse: es la diferencia entre reproducir el recorte y declararlo.
                storedLength: min(UInt32(clamping: chunk.bytes.count), Self.maxRecordBytes),
                originalLength: UInt32(clamping: chunk.bytes.count)
            )
        }
        await writer.close()

        return metas.map { $0.compactMap { $0 } }
    }

    /// El tope por registro con el que se construye el escritor. Es el suyo por defecto y se nombra
    /// aquí porque el fixture necesita saberlo para escribir el `storedLength` de la fila.
    private static let maxRecordBytes: UInt32 = 64 * 1024

    // MARK: - El historial

    private func writeHistory(
        _ fixture: CaptureFixture,
        locations: [[CaptureLocation?]],
        plaintext: [[PlaintextChunkMeta]],
        into store: FlowStore
    ) async throws {
        for (flowIndex, flow) in fixture.flows.enumerated() {
            let id = try await store.upsertFlow(flow.record)
            let metas = flow.packets.enumerated().map { packetIndex, packet in
                packet.meta(capturedAt: locations[flowIndex][packetIndex])
            }
            try await store.appendPackets(metas, flowID: id)

            let chunks = plaintext[flowIndex]
            if !chunks.isEmpty {
                try await store.appendPlaintext(chunks, flowID: id)
            }
        }
    }
}

#endif
