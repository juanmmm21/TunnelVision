import Foundation
import XCTest
@testable import Shared

/// Tests del sembrador de capturas sintéticas (M11): la mitad que escribe.
///
/// Lo que se afirma aquí no es que el disco quede escrito, sino que **lo escrito es lo que la app
/// lee**: la captura se siembra y se vuelve a leer con los mismos servicios que usan las pantallas
/// (`HistoryReader`, `CaptureLibrary`), no con una lectura propia que se validaría a sí misma. Eso es
/// lo único que demuestra que un paquete sembrado lleva a *sus* bytes, que es exactamente lo que la
/// pareja fichero+offset existe para garantizar.
///
/// Todo va contra un directorio y una BD temporales, por el `init` de rutas. `SeedError.appGroupUnavailable`
/// **no se puede provocar aquí**: en Simulator `containerURL(forSecurityApplicationGroupIdentifier:)`
/// resuelve para cualquier identificador, así que el caso "falta el entitlement" no existe en esta
/// máquina — es la misma limitación que ya tiene anotada `CaptureLibraryTests`, y allí se rodea con la
/// costura que el servicio necesitaba de todas formas (resuelve en cada llamada, para una pantalla).
/// El sembrador resuelve una sola vez al construirse y le contesta a una consola, así que no la tiene.
final class FixtureSeederTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seeder-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    /// Especificación pequeña: aquí interesa la forma de lo escrito, no el tamaño. La de verdad son
    /// miles de paquetes y sembrarla en cada caso multiplicaría por veinte lo que tarda la suite.
    private func spec(
        seed: UInt64 = 42,
        bulkFlowCount: Int = 6,
        busiestFlowPacketCount: Int = 12
    ) -> FixtureSpec {
        FixtureSpec(
            seed: seed,
            endingAt: Date(timeIntervalSince1970: 1_800_000_000),
            span: 6 * 3600,
            bulkFlowCount: bulkFlowCount,
            busiestFlowPacketCount: busiestFlowPacketCount
        )
    }

    private func destination(
        _ name: String = "shared"
    ) -> (database: URL, captures: URL, plaintext: URL) {
        let root = tempDir.appendingPathComponent(name, isDirectory: true)
        return (
            root.appendingPathComponent("TunnelVision.sqlite"),
            root.appendingPathComponent("Captures", isDirectory: true),
            root.appendingPathComponent("Plaintext", isDirectory: true)
        )
    }

    private func makeSeeder(
        _ name: String = "shared",
        configuration: FixtureSeeder.Configuration = FixtureSeeder.Configuration()
    ) throws -> (seeder: FixtureSeeder, database: URL, captures: URL, plaintext: URL) {
        let paths = destination(name)
        try FileManager.default.createDirectory(
            at: paths.database.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return (
            FixtureSeeder(
                databaseURL: paths.database,
                captureDirectory: paths.captures,
                plaintextDirectory: paths.plaintext,
                configuration: configuration
            ),
            paths.database,
            paths.captures,
            paths.plaintext
        )
    }

    // MARK: - Round trip: lo sembrado es lo que la app lee

    /// El test que justifica todo lo demás: se siembra y se lee con el `HistoryReader` de la app, que
    /// es el mismo camino que recorre la Timeline. Sin esto, "escribe en disco" sería una afirmación
    /// sobre ficheros y no sobre pantallas.
    func testSeededHistoryIsReadBackByTheAppsOwnReader() async throws {
        let (seeder, database, _, _) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        let report = try await seeder.seed(fixture)
        XCTAssertEqual(report.flowCount, fixture.flows.count)
        XCTAssertEqual(report.packetCount, fixture.packetCount)

        let store = try FlowStore(databaseURL: database)
        let reader = HistoryReader(store: store)
        // Una página por flujo sembrado: leer lo que hay, no lo que la política pagina.
        let page = try await reader.flowPage(limit: fixture.flows.count + 10, after: nil)

        XCTAssertEqual(page.count, fixture.flows.count)
        XCTAssertEqual(
            Set(page.map(\.stored.key)), Set(fixture.flows.map(\.key)),
            "cada flujo sembrado tiene que salir con su propia 5-tupla"
        )

        let byKey = Dictionary(uniqueKeysWithValues: page.map { ($0.stored.key, $0) })
        for flow in fixture.flows {
            let read = try XCTUnwrap(byKey[flow.key])
            XCTAssertEqual(read.stored.sni, flow.sni)
            XCTAssertEqual(read.stored.tlsStatus, flow.tlsStatus)
            XCTAssertEqual(read.stored.packetCount, flow.record.packetCount)
            XCTAssertEqual(read.stored.bytesOut, flow.record.bytesOut)
            XCTAssertEqual(read.stored.bytesIn, flow.record.bytesIn)
            XCTAssertNotNil(
                read.endpoints,
                "la app tiene que poder separar el extremo remoto del dispositivo: \(flow.key)"
            )
        }
    }

    /// El historial se fecha con el ancla **de la captura** y no con la de "ahora". Es la única
    /// decisión del sembrador que no tiene síntoma visible si se hace mal: con `.now()` todo saldría
    /// coherente entre sí y seis horas movido, y la Timeline abriría en un futuro que no existe.
    func testHistoryIsDatedByTheFixturesAnchorAndNotByNow() async throws {
        let (seeder, database, _, _) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        _ = try await seeder.seed(fixture)

        let store = try FlowStore(databaseURL: database)
        let flows = try await store.recentFlows(limit: fixture.flows.count + 10)
        let expected = Dictionary(uniqueKeysWithValues: fixture.flows.map { ($0.key, $0.record) })

        for stored in flows {
            let record = try XCTUnwrap(expected[stored.key])
            // Un milisegundo de holgura: el ancla viaja a disco en nanosegundos enteros pero `Date`
            // pierde resolución por debajo de ~256 ns para el epoch actual (ver `WallClock`).
            XCTAssertEqual(
                stored.firstSeen.timeIntervalSince1970,
                fixture.anchor.date(forUptime: record.firstSeen).timeIntervalSince1970,
                accuracy: 0.001
            )
            XCTAssertEqual(
                stored.lastSeen.timeIntervalSince1970,
                fixture.anchor.date(forUptime: record.lastSeen).timeIntervalSince1970,
                accuracy: 0.001
            )
        }

        let newest = try XCTUnwrap(flows.map(\.lastSeen).max())
        XCTAssertEqual(
            newest.timeIntervalSince1970,
            spec().endingAt.timeIntervalSince1970,
            accuracy: 0.001,
            "el paquete más reciente cae donde la especificación pidió, no donde caiga el reloj"
        )
    }

    // MARK: - Los bytes: cada paquete lleva a los suyos

    /// La afirmación que la pareja fichero+offset existe para poder hacer, y la razón por la que el
    /// sembrador escribe con el `PcapWriter` de verdad en vez de componer los registros por su cuenta:
    /// se lee cada localización guardada con la `CaptureLibrary` de la app y se comprueba que devuelve
    /// **esos** bytes. Un sembrador que calculara los offsets aparte pasaría su propio test y llevaría
    /// la pantalla de un paquete a los bytes de otra conexión.
    func testEveryStoredLocationResolvesToItsOwnBytes() async throws {
        let (seeder, database, captures, _) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        _ = try await seeder.seed(fixture)

        let store = try FlowStore(databaseURL: database)
        let library = CaptureLibrary(directory: captures)
        var checked = 0

        for flow in fixture.flows {
            let match = try await store.flow(matching: flow.key)
            let stored = try XCTUnwrap(match)
            let packets = try await store.packets(forFlow: stored.id, limit: flow.packets.count + 10)
            XCTAssertEqual(packets.count, flow.packets.count)

            // Ambas listas van en orden temporal ascendente, así que se emparejan por posición.
            for (expected, read) in zip(flow.packets, packets) {
                XCTAssertEqual(read.length, expected.length)
                XCTAssertEqual(read.tcpFlags, expected.tcpFlags)
                XCTAssertEqual(read.direction, expected.direction)

                guard expected.wasCaptured else {
                    XCTAssertNil(
                        read.capture,
                        "un paquete cuyos bytes no se escribieron no puede señalar un registro"
                    )
                    continue
                }
                let location = try XCTUnwrap(read.capture)
                let record = try await library.record(at: location)
                XCTAssertEqual(record.bytes, expected.bytes)
                XCTAssertEqual(record.originalLength, expected.length)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "el fixture tiene que traer paquetes capturados")
    }

    /// El flujo escrito para no capturar nada sigue en el historial y no tiene ni un byte en disco:
    /// es el caso que hace visible la pantalla de un paquete sin nada que enseñar.
    func testTheFlowThatCapturesNothingKeepsItsHistoryAndNoBytes() async throws {
        let (seeder, database, _, _) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())
        let uncaptured = try XCTUnwrap(fixture.flows.first { $0.packets.allSatisfy { !$0.wasCaptured } })

        _ = try await seeder.seed(fixture)

        let store = try FlowStore(databaseURL: database)
        let match = try await store.flow(matching: uncaptured.key)
            let stored = try XCTUnwrap(match)
        let packets = try await store.packets(forFlow: stored.id, limit: 1000)

        XCTAssertEqual(packets.count, uncaptured.packets.count)
        XCTAssertTrue(packets.allSatisfy { $0.capture == nil })
    }

    // MARK: - Los ficheros

    /// Una captura es un fichero por dispositivo y no uno por conexión, así que sus registros van en
    /// el orden en que ocurrieron **cruzando los flujos**. Escribirlos flujo a flujo dejaría cada
    /// conexión ordenada y el fichero entero yendo hacia atrás, que es algo que ninguna captura real
    /// hace.
    func testRecordsAreWrittenInTheOrderThePacketsHappened() async throws {
        let (seeder, database, captures, _) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        _ = try await seeder.seed(fixture)

        let store = try FlowStore(databaseURL: database)
        let library = CaptureLibrary(directory: captures)

        // Todas las localizaciones guardadas, con el sello del paquete que las señala.
        var stamps: [(sequence: UInt32, offset: UInt64, timestamp: UInt64)] = []
        for flow in fixture.flows {
            let match = try await store.flow(matching: flow.key)
            let stored = try XCTUnwrap(match)
            let packets = try await store.packets(forFlow: stored.id, limit: 5000)
            for (expected, read) in zip(flow.packets, packets) {
                guard let location = read.capture else { continue }
                stamps.append((location.fileSequence, location.recordOffset, expected.timestamp))
            }
        }
        XCTAssertGreaterThan(stamps.count, 1)

        // Ordenados por (fichero, offset) —que es el orden en que están escritos— los sellos no
        // pueden decrecer.
        let inWriteOrder = stamps.sorted { ($0.sequence, $0.offset) < ($1.sequence, $1.offset) }
        for (earlier, later) in zip(inWriteOrder, inWriteOrder.dropFirst()) {
            XCTAssertLessThanOrEqual(
                earlier.timestamp, later.timestamp,
                "el fichero \(later.sequence) retrocede en el offset \(later.offset)"
            )
        }

        // Y los ficheros se suceden: todo lo del anterior es anterior a todo lo del siguiente.
        let files = try await library.files()
        XCTAssertGreaterThan(files.count, 1)
        for (earlier, later) in zip(files, files.dropFirst()) {
            let lastOfEarlier = try XCTUnwrap(
                stamps.filter { $0.sequence == earlier.sequence }.map(\.timestamp).max()
            )
            let firstOfLater = try XCTUnwrap(
                stamps.filter { $0.sequence == later.sequence }.map(\.timestamp).min()
            )
            XCTAssertLessThanOrEqual(lastOfEarlier, firstOfLater)
        }
    }

    /// Los registros del `.pcap` sembrado llevan la **hora de pared** del fixture, igual que los del
    /// dispositivo: el sello del fixture es monotónico y se convierte con su ancla antes de escribir.
    /// Sin esa conversión, una captura sembrada se abre en Wireshark fechada en 1970 y no sirve para
    /// enseñar el producto, que es justo para lo que existe el sembrador.
    func testSeededRecordsAreDatedByTheFixturesWallClock() async throws {
        let (seeder, database, captures, _) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        _ = try await seeder.seed(fixture)

        let store = try FlowStore(databaseURL: database, anchor: fixture.anchor)
        let library = CaptureLibrary(directory: captures)

        var checked = 0
        for flow in fixture.flows {
            let match = try await store.flow(matching: flow.key)
            let stored = try XCTUnwrap(match)
            let packets = try await store.packets(forFlow: stored.id, limit: 5000)
            for (expected, read) in zip(flow.packets, packets) {
                guard let location = read.capture else { continue }
                let record = try await library.record(at: location)
                let written = fixture.anchor.nanosecondsSince1970(forUptime: expected.timestamp)
                XCTAssertEqual(record.timestampMicroseconds, UInt64(written / 1_000))
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    /// La captura se reparte en el número de ficheros que se pide, y no en el que salga de un tope de
    /// bytes: es lo que garantiza que la pantalla de capturas tenga más de una fila —su estado
    /// interesante— sea cual sea el tamaño del fixture.
    func testTheCaptureIsSplitIntoTheRequestedNumberOfFiles() async throws {
        for requested in [1, 2, 5] {
            let (seeder, _, captures, _) = try makeSeeder(
                "files-\(requested)",
                configuration: FixtureSeeder.Configuration(captureFileCount: requested)
            )
            let report = try await seeder.seed(CaptureFixture.make(spec()))

            XCTAssertEqual(report.captureFileSequences.count, requested)
            XCTAssertEqual(CaptureDirectory.files(in: captures).count, requested)
            XCTAssertEqual(
                report.captureFileSequences, Array(0..<UInt32(requested)),
                "las secuencias arrancan en 0: el directorio y el historial se vacían antes"
            )
        }
    }

    /// Ningún fichero se queda con solo su cabecera global. Un `.pcap` sin registros sale en la lista
    /// de capturas como una fila que no lleva a ningún sitio, y rotar delante del primer paquete es la
    /// forma fácil de producirlo.
    func testNoCaptureFileIsLeftEmpty() async throws {
        let (seeder, _, captures, _) = try makeSeeder(
            configuration: FixtureSeeder.Configuration(captureFileCount: 4)
        )
        _ = try await seeder.seed(CaptureFixture.make(spec()))

        for file in CaptureDirectory.files(in: captures) {
            let size = try XCTUnwrap(file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            XCTAssertGreaterThan(
                size, PcapFormat.globalHeaderSize,
                "el fichero \(file.sequence) no tiene ni un registro"
            )
        }
    }

    /// Los cortes se piden a una función pura, así que se afirman directamente: nunca la posición 0
    /// (rotar antes del primer paquete deja un fichero vacío), tantos cortes como ficheros menos uno,
    /// y nunca más ficheros que paquetes.
    func testRotationBoundariesNeverProduceAnEmptyFile() {
        XCTAssertEqual(FixtureSeeder.rotationBoundaries(packetCount: 10, fileCount: 1), [])
        XCTAssertEqual(FixtureSeeder.rotationBoundaries(packetCount: 10, fileCount: 2), [5])
        XCTAssertEqual(FixtureSeeder.rotationBoundaries(packetCount: 10, fileCount: 3), [3, 6])
        XCTAssertEqual(FixtureSeeder.rotationBoundaries(packetCount: 1, fileCount: 5), [])
        XCTAssertEqual(FixtureSeeder.rotationBoundaries(packetCount: 0, fileCount: 3), [])

        for count in 1...40 {
            for files in 1...8 {
                let boundaries = FixtureSeeder.rotationBoundaries(packetCount: count, fileCount: files)
                XCTAssertFalse(boundaries.contains(0), "rotar antes del primer paquete deja un vacío")
                XCTAssertEqual(boundaries.count, min(files, count) - 1)
                XCTAssertTrue(boundaries.allSatisfy { $0 > 0 && $0 < count })
            }
        }
    }

    /// Cada fichero se queda con el nombre y la fecha de creación de su primer registro. La pantalla
    /// de capturas lee esa fecha del sistema de ficheros —el nombre no se parsea nunca—, así que
    /// dejarlos en "ahora" enseñaría seis horas de historial en ficheros que dicen haberse abierto
    /// hace un segundo.
    func testEachCaptureFileIsNamedAndDatedByItsFirstRecord() async throws {
        let (seeder, database, captures, _) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        _ = try await seeder.seed(fixture)

        let store = try FlowStore(databaseURL: database)
        var firstStamp: [UInt32: UInt64] = [:]
        for flow in fixture.flows {
            let match = try await store.flow(matching: flow.key)
            let stored = try XCTUnwrap(match)
            let packets = try await store.packets(forFlow: stored.id, limit: 5000)
            for (expected, read) in zip(flow.packets, packets) {
                guard let location = read.capture else { continue }
                let current = firstStamp[location.fileSequence]
                if current == nil || expected.timestamp < current! {
                    firstStamp[location.fileSequence] = expected.timestamp
                }
            }
        }

        let library = CaptureLibrary(directory: captures)
        let files = try await library.files()
        XCTAssertFalse(files.isEmpty)

        for file in files {
            let stamp = try XCTUnwrap(firstStamp[file.sequence])
            let expected = fixture.anchor.date(forUptime: stamp)

            XCTAssertEqual(
                file.url.lastPathComponent,
                CaptureFileName.make(sequence: file.sequence, date: expected)
            )
            let created = try XCTUnwrap(file.createdAt)
            XCTAssertEqual(
                created.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1,
                "la fecha del sistema de ficheros es la del primer registro del fichero"
            )
        }
    }

    // MARK: - Sembrar dos veces

    /// Sembrar **reemplaza**. Es lo que hace que el argumento de lanzamiento se pueda repetir sin
    /// pensarlo y, sobre todo, que dos mediciones con la misma semilla midan el mismo trabajo:
    /// acumular convertiría la reproducibilidad del generador en una promesa que el disco desmiente.
    func testSeedingTwiceReplacesInsteadOfAccumulating() async throws {
        let (seeder, database, captures, _) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        let first = try await seeder.seed(fixture)
        XCTAssertEqual(first.replacedFlowCount, 0)
        XCTAssertEqual(first.replacedCaptureFileCount, 0)

        let second = try await seeder.seed(fixture)
        XCTAssertEqual(second.replacedFlowCount, fixture.flows.count)
        XCTAssertEqual(second.replacedCaptureFileCount, first.captureFileSequences.count)

        let store = try FlowStore(databaseURL: database)
        let remaining = try await store.flowCount()
        XCTAssertEqual(remaining, fixture.flows.count)
        XCTAssertEqual(
            CaptureDirectory.files(in: captures).count, first.captureFileSequences.count
        )
        XCTAssertEqual(second.captureFileSequences, first.captureFileSequences)
    }

    /// El directorio de capturas es compartido: el sembrador se lleva las capturas nuestras y **solo**
    /// esas. Borrar lo que no reconoce sería pasarse del encargo.
    func testSeedingLeavesForeignFilesAlone() async throws {
        let (seeder, _, captures, _) = try makeSeeder()
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let foreign = captures.appendingPathComponent("notes.txt")
        try Data("no soy una captura".utf8).write(to: foreign)

        _ = try await seeder.seed(CaptureFixture.make(spec()))

        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    // MARK: - Reproducibilidad

    /// La propiedad de la que depende todo lo que se construya encima: la misma captura sembrada dos
    /// veces deja los mismos ficheros, con los mismos nombres y los mismos bytes. Sin esto, un
    /// «antes y después» con Instruments compararía dos capturas distintas.
    func testTheSameFixtureWritesByteIdenticalFiles() async throws {
        let (left, _, leftCaptures, leftPlaintext) = try makeSeeder("left")
        let (right, _, rightCaptures, rightPlaintext) = try makeSeeder("right")
        let fixture = CaptureFixture.make(spec())

        _ = try await left.seed(fixture)
        _ = try await right.seed(fixture)

        let leftFiles = CaptureDirectory.files(in: leftCaptures)
        let rightFiles = CaptureDirectory.files(in: rightCaptures)
        XCTAssertEqual(leftFiles.map(\.url.lastPathComponent), rightFiles.map(\.url.lastPathComponent))
        XCTAssertFalse(leftFiles.isEmpty)

        for (a, b) in zip(leftFiles, rightFiles) {
            XCTAssertEqual(try Data(contentsOf: a.url), try Data(contentsOf: b.url))
        }

        // Y lo mismo con lo descifrado, que es la mitad más fácil de dejar fuera: sus ficheros no
        // llevan la fecha en el nombre, así que un fallo de reproducibilidad aquí solo se ve en los
        // bytes.
        let leftDecrypted = PlaintextDirectory.files(in: leftPlaintext)
        let rightDecrypted = PlaintextDirectory.files(in: rightPlaintext)
        XCTAssertEqual(leftDecrypted.map(\.sequence), rightDecrypted.map(\.sequence))
        XCTAssertFalse(leftDecrypted.isEmpty)
        for (a, b) in zip(leftDecrypted, rightDecrypted) {
            XCTAssertEqual(try Data(contentsOf: a.url), try Data(contentsOf: b.url))
        }
    }

    // MARK: - El resumen

    /// El resumen es un diagnóstico de consola, no copia de producto: no pasa por el catálogo. Lo que
    /// se afirma es que lleva los números que hacen falta para saber que sembrar terminó y qué dejó.
    func testTheReportSummarisesWhatWasWritten() async throws {
        let (seeder, _, _, _) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        let report = try await seeder.seed(fixture)
        let summary = report.summary

        XCTAssertTrue(summary.contains("\(fixture.flows.count) connections"))
        XCTAssertTrue(summary.contains("\(fixture.packetCount) packets"))
        XCTAssertTrue(summary.contains("\(fixture.capturedPacketCount) with bytes"))
        XCTAssertTrue(summary.contains("\(report.captureFileSequences.count) capture files"))
        XCTAssertGreaterThan(report.captureBytes, 0)
        XCTAssertEqual(report.span, fixture.wallClockSpan)
    }

    // MARK: - El contenido descifrado

    /// El test que justifica la mitad descifrada del sembrador: se siembra y se lee con los dos
    /// servicios que usa la pantalla —el índice por `HistoryReader` y los bytes por
    /// `PlaintextLibrary`—, que es el camino entero del Flow Inspector a un `.tvpt`.
    func testSeededPlaintextIsReadBackByTheAppsOwnServices() async throws {
        let (seeder, database, _, plaintextDirectory) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        let report = try await seeder.seed(fixture)

        XCTAssertEqual(report.plaintextChunkCount, fixture.plaintextChunkCount)
        XCTAssertGreaterThan(report.plaintextBytes, 0)

        let reader = HistoryReader(store: try FlowStore(databaseURL: database, anchor: fixture.anchor))
        let library = PlaintextLibrary(directory: plaintextDirectory)
        let flows = try await reader.flowPage(limit: 500, after: nil)
        var read = 0

        for flow in flows {
            let chunks = try await reader.plaintext(forFlow: flow.id)
            for chunk in chunks {
                let record = try await library.record(for: chunk)
                XCTAssertEqual(record.stream, chunk.stream)
                XCTAssertEqual(record.direction, chunk.direction)
                XCTAssertEqual(UInt32(record.bytes.count), chunk.storedLength)
                read += 1
            }
        }

        XCTAssertEqual(read, fixture.plaintextChunkCount)
    }

    /// El recorte lo produce el escritor y no el fixture, así que tiene que llegar hasta la fila: sin
    /// esto el estado "esto no se guardó entero" no existiría en Simulator.
    func testThePieceThatDoesNotFitArrivesTruncated() async throws {
        let (seeder, database, _, _) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        _ = try await seeder.seed(fixture)

        let reader = HistoryReader(store: try FlowStore(databaseURL: database, anchor: fixture.anchor))
        var truncated: [StoredPlaintextChunk] = []
        for flow in try await reader.flowPage(limit: 500, after: nil) {
            truncated += try await reader.plaintext(forFlow: flow.id).filter(\.isTruncated)
        }

        XCTAssertEqual(truncated.count, 1)
        XCTAssertEqual(truncated.first?.storedLength, 64 * 1024)
        XCTAssertGreaterThan(truncated.first?.originalLength ?? 0, 64 * 1024)
    }

    /// Un fichero `.tvpt` intercala conversaciones a propósito, y es lo que la `stream` de cada
    /// registro existe para desenredar. Escribirlos flujo a flujo dejaría esa propiedad sin ejercitar.
    func testConversationsAreInterleavedInsideTheFiles() async throws {
        let (seeder, database, _, _) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        _ = try await seeder.seed(fixture)

        let reader = HistoryReader(store: try FlowStore(databaseURL: database, anchor: fixture.anchor))
        var streamsBySequence: [UInt32: Set<UInt64>] = [:]
        for flow in try await reader.flowPage(limit: 500, after: nil) {
            for chunk in try await reader.plaintext(forFlow: flow.id) {
                streamsBySequence[chunk.location.fileSequence, default: []].insert(chunk.stream)
            }
        }

        XCTAssertTrue(streamsBySequence.values.contains { $0.count > 1 })
    }

    /// Sembrar **reemplaza** también aquí, y sin llevarse las capturas por delante: son dos
    /// directorios con dos retenciones distintas (ADR 0007).
    func testSeedingAgainReplacesTheDecryptedContentAndLeavesTheCapturesAlone() async throws {
        let (seeder, _, captures, plaintextDirectory) = try makeSeeder()
        let fixture = CaptureFixture.make(spec())

        let first = try await seeder.seed(fixture)
        let second = try await seeder.seed(fixture)

        XCTAssertEqual(second.plaintextChunkCount, first.plaintextChunkCount)
        XCTAssertEqual(second.plaintextBytes, first.plaintextBytes)
        XCTAssertEqual(
            PlaintextDirectory.files(in: plaintextDirectory).map(\.sequence),
            [0],
            "el directorio se vacía antes de escribir, así que la secuencia vuelve a empezar"
        )
        XCTAssertFalse(CaptureDirectory.files(in: captures).isEmpty)
    }
}
