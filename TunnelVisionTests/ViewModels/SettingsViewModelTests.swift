import Foundation
import XCTest
@testable import Shared

/// Tests del view model de Ajustes (M9) contra piezas **reales**: un `StorageManager` sobre un
/// directorio temporal poblado por un `PcapWriter` real y una BD temporal con un `FlowStore` real, y
/// un `CaptureLibrary` real sobre ese mismo directorio.
///
/// Solo hay dos cosas guionizadas, y por el mismo motivo que en las otras pantallas: el **canal de
/// control** (va a un túnel que en Simulator no existe, y sus desenlaces son justo lo que hay que
/// afirmar) y el **soporte de los ajustes** (un `UserDefaults` real no sabe fallar ni guardar basura
/// a voluntad, que es la costura que `SettingsStore` expone para eso).
@MainActor
final class SettingsViewModelTests: XCTestCase {

    private var captures: URL!
    /// El directorio del contenido descifrado. No se crea en `setUp`: lo crea su escritor con el
    /// primer byte que haya que guardar, así que no existir es su estado normal.
    private var plaintext: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        captures = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-vm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        plaintext = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-vm-plaintext-\(UUID().uuidString)", isDirectory: true)
        dbURL = PersistenceFixtures.temporaryDatabaseURL()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: captures)
        try? FileManager.default.removeItem(at: plaintext)
        PersistenceFixtures.removeDatabase(at: dbURL)
    }

    // MARK: - Utilidades

    /// El blob de ajustes en memoria: lo que sustituye al `UserDefaults` del App Group.
    private final class Blob: @unchecked Sendable {
        var data: Data?
        var writeError: SettingsStoreError?
    }

    /// Ancla de la BD, 30 días atrás, para que un flujo escrito con sellos pequeños quede de verdad
    /// viejo frente a un corte por antigüedad real (mismo truco que en `StorageManagerTests`).
    private var anchor: MonotonicAnchor {
        MonotonicAnchor(uptimeNanoseconds: 1_000_000_000, wallClock: Date().addingTimeInterval(-30 * 86_400))
    }

    private func makeStore(_ blob: Blob) -> SettingsStore {
        SettingsStore(
            reading: { blob.data },
            writing: { data in
                if let error = blob.writeError { throw error }
                blob.data = data
            }
        )
    }

    private func makeStorage(directory: URL? = nil) -> StorageManager {
        let url = dbURL!
        let anchor = anchor
        return StorageManager(
            library: CaptureLibrary(directory: directory ?? captures),
            openingStore: { try FlowStore(databaseURL: url, anchor: anchor) },
            plaintextDirectory: plaintext
        )
    }

    private func makeViewModel(
        blob: Blob = Blob(),
        library: CaptureLibrary? = nil,
        storage: StorageManager? = nil,
        availability: @escaping @Sendable () async -> TLSInspectionAvailability = { .certificateNotReady },
        send: @escaping @Sendable (ControlCommand) async throws -> ControlResponse = { _ in .ok }
    ) -> SettingsViewModel {
        SettingsViewModel(
            store: makeStore(blob),
            storage: storage ?? makeStorage(),
            library: library ?? CaptureLibrary(directory: captures),
            send: send,
            availability: availability
        )
    }

    /// Escribe `count` capturas de un registro cada una, rotando entre ellas.
    private func writeCaptures(_ count: Int) async throws {
        let writer = try PcapWriter(config: .init(directory: captures, snaplen: 262_144))
        for index in 0..<count {
            _ = try await writer.write(
                packet: Data(repeating: UInt8(index), count: 64),
                originalLength: 64,
                timestamp: Int64(index + 1) * 1_000
            )
            if index < count - 1 { try await writer.rotate() }
        }
        await writer.close()
    }

    /// Envejece los ficheros del directorio: la retención por antigüedad mira la fecha de creación
    /// del **sucesor** de cada fichero, así que sin esto nada escrito ahora mismo puede caducar.
    private func ageCaptures(byDays days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        for file in CaptureDirectory.files(in: captures) {
            try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: file.url.path)
        }
    }

    private func remainingSequences() -> [UInt32] {
        CaptureDirectory.files(in: captures).map(\.sequence)
    }

    private func makeFlow(secondsAfterAnchor: UInt64) async throws {
        let store = try FlowStore(databaseURL: dbURL, anchor: anchor)
        let id = try await store.upsertFlow(
            PersistenceFixtures.flow(
                remote: ModelFixtures.v4(1, 1, 1, 1),
                firstSeen: secondsAfterAnchor,
                lastSeen: secondsAfterAnchor
            )
        )
        try await store.appendPackets(
            [PersistenceFixtures.packet(timestamp: secondsAfterAnchor, key: PersistenceFixtures.key(remote: ModelFixtures.v4(1, 1, 1, 1)))],
            flowID: id
        )
    }

    // MARK: - Carga

    func testRefreshShowsWhatWasSavedAndWhatIsOnDisk() async throws {
        let blob = Blob()
        try makeStore(blob).save(
            AppSettings(captureEnabled: false, captureDetail: .metadataOnly, retention: .init(maxAge: .unlimited, maxCaptureSize: .unlimited))
        )
        try await writeCaptures(2)
        let viewModel = makeViewModel(blob: blob)

        await viewModel.refresh()

        XCTAssertFalse(viewModel.settings.captureEnabled)
        XCTAssertEqual(viewModel.settings.captureDetail, .metadataOnly)
        XCTAssertEqual(viewModel.usage?.captureFileCount, 2)
        XCTAssertEqual(viewModel.activity, .idle)
        XCTAssertNil(viewModel.notice)
    }

    func testUnreadableSettingsShowTheDefaultsAndAreRepairedByTheFirstSave() async throws {
        let blob = Blob()
        blob.data = Data("no soy JSON".utf8)
        let viewModel = makeViewModel(blob: blob)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.settings, .default)
        XCTAssertEqual(viewModel.notice?.role, .warning)

        await viewModel.setCaptureEnabled(false)

        // La escritura repara el blob: lo guardado vuelve a leerse, y el aviso deja de tener sentido.
        XCTAssertNil(viewModel.notice)
        XCTAssertEqual(try makeStore(blob).load().captureEnabled, false)
    }

    func testNothingStoredIsNotAnError() async throws {
        let viewModel = makeViewModel()

        await viewModel.refresh()

        XCTAssertEqual(viewModel.settings, .default)
        XCTAssertNil(viewModel.notice)
    }

    // MARK: - Guardar

    func testASettingThatCannotBeSavedGoesBackToWhatItWas() async throws {
        let blob = Blob()
        let viewModel = makeViewModel(blob: blob)
        await viewModel.refresh()
        blob.writeError = .writeFailed("read-only")

        await viewModel.setCaptureEnabled(false)

        // Dejar el interruptor en la posición nueva afirmaría que se guardó.
        XCTAssertTrue(viewModel.settings.captureEnabled)
        XCTAssertEqual(viewModel.notice?.role, .warning)
        XCTAssertNil(blob.data)
    }

    func testAChangeReachesTheLiveSessionOnlyWhileMonitoring() async throws {
        let sent = Sent()
        let viewModel = makeViewModel(send: { command in
            sent.commands.append(command)
            return .ok
        })
        await viewModel.refresh()

        await viewModel.setCaptureEnabled(false)
        XCTAssertTrue(sent.commands.isEmpty, "con el túnel parado no hay a quién mandarle nada")

        viewModel.tunnelStateDidChange(to: .live)
        await viewModel.setCaptureEnabled(true)

        XCTAssertEqual(sent.commands, [.setCaptureEnabled(true)])
    }

    func testALiveSessionThatRejectsTheChangeStillLeavesItSaved() async throws {
        let blob = Blob()
        let viewModel = makeViewModel(blob: blob, send: { _ in .failed("disk full") })
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.setCaptureEnabled(false)

        XCTAssertFalse(viewModel.settings.captureEnabled)
        XCTAssertEqual(try makeStore(blob).load().captureEnabled, false)
        XCTAssertEqual(viewModel.notice?.role, .warning)
        XCTAssertEqual(viewModel.notice?.diagnostic, "disk full")
    }

    func testATunnelThatStoppedMidGestureIsNotReportedAsAFailure() async throws {
        let viewModel = makeViewModel(send: { _ in .notRunning })
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.setCaptureEnabled(false)

        // Es la carrera normal entre la UI y `stopTunnel`: el ajuste está guardado para la próxima.
        XCTAssertFalse(viewModel.settings.captureEnabled)
        XCTAssertNil(viewModel.notice)
    }

    // MARK: - Detalle de captura

    /// Alcanza a la sesión viva, y cuesta un fichero: el `snaplen` va en la cabecera global del `.pcap`,
    /// así que la extensión rota al aplicarlo. Eso el usuario lo ve en su lista de capturas, y por eso
    /// se le dice en vez de dejar que aparezca sola.
    func testCaptureDetailReachesTheLiveSessionAndSaysItStartedANewFile() async throws {
        let blob = Blob()
        let sent = Sent()
        let viewModel = makeViewModel(blob: blob, send: { command in
            sent.commands.append(command)
            return .ok
        })
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.setCaptureDetail(.metadataOnly)

        XCTAssertEqual(try makeStore(blob).load().captureDetail, .metadataOnly)
        XCTAssertEqual(sent.commands, [.setCaptureDetail(.metadataOnly)])
        XCTAssertEqual(viewModel.notice, SettingsPresentation.captureDetailStartedANewFile)
    }

    /// Que la sesión rechace el cambio se cuenta con **su** aviso y no con el de "se abrió un fichero
    /// nuevo": justamente no se abrió ninguno, y decir lo contrario dejaría al usuario creyendo que
    /// captura con un detalle que no tiene.
    func testARejectedDetailChangeDoesNotClaimANewFileWasStarted() async throws {
        let viewModel = makeViewModel(send: { _ in .failed("disk full") })
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.setCaptureDetail(.metadataOnly)

        XCTAssertEqual(viewModel.notice, SettingsPresentation.liveChangeNotApplied("disk full"))
    }

    func testWithMonitoringStoppedTheDetailNeedsNoExplanation() async throws {
        let viewModel = makeViewModel()
        await viewModel.refresh()

        await viewModel.setCaptureDetail(.metadataOnly)

        // No hay sesión a la que no alcance: la próxima que arranque ya lo lee.
        XCTAssertNil(viewModel.notice)
    }

    // MARK: - Inspección TLS

    func testInspectionCannotBeTurnedOnWithoutTheCertificate() async throws {
        let blob = Blob()
        let viewModel = makeViewModel(blob: blob, availability: { .certificateNotReady })
        await viewModel.refresh()

        await viewModel.setTLSInspection(true)

        XCTAssertFalse(viewModel.settings.tlsInspectionEnabled)
        XCTAssertNil(blob.data, "un ajuste que no se puede cumplir no se guarda")
        XCTAssertEqual(viewModel.notice, SettingsPresentation.tlsCannotBeEnabled)
        XCTAssertFalse(viewModel.isTLSInspectionEditable)
    }

    func testWithTheCertificateReadyInspectionIsSavedAndAppliedLive() async throws {
        let sent = Sent()
        let viewModel = makeViewModel(
            availability: { .ready },
            send: { command in
                sent.commands.append(command)
                return .ok
            }
        )
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.setTLSInspection(true)

        XCTAssertTrue(viewModel.settings.tlsInspectionEnabled)
        XCTAssertEqual(sent.commands, [.setTLSInspectionEnabled(true)])
    }

    func testInspectionCanAlwaysBeTurnedOffEvenIfTheCertificateIsGone() async throws {
        let blob = Blob()
        try makeStore(blob).save(AppSettings(tlsInspectionEnabled: true))
        let viewModel = makeViewModel(blob: blob, availability: { .certificateNotReady })
        await viewModel.refresh()

        // Que ya esté encendida es lo que garantiza que el interruptor se pueda tocar: una función
        // que solo se apaga cuando el sistema coopera sería irreversible en la práctica.
        XCTAssertTrue(viewModel.isTLSInspectionEditable)

        await viewModel.setTLSInspection(false)

        XCTAssertFalse(viewModel.settings.tlsInspectionEnabled)
        XCTAssertEqual(try makeStore(blob).load().tlsInspectionEnabled, false)
    }

    // MARK: - La revalidación de la confianza

    /// El caso que costó una sesión de dispositivo: la inspección quedó encendida con una CA que el
    /// sistema no acepta, y entonces **cada** conexión al 443 se termina con un certificado que nadie
    /// valida — o sea, el dispositivo sin navegación. Al volver a la app se apaga sola y se dice.
    func testInspectionTurnsItselfOffWhenTheSystemStopsAcceptingTheCA() async throws {
        let blob = Blob()
        try makeStore(blob).save(AppSettings(tlsInspectionEnabled: true))
        let sent = Sent()
        let viewModel = makeViewModel(
            blob: blob,
            availability: { .certificateNotReady },
            send: { command in
                sent.commands.append(command)
                return .ok
            }
        )
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.revalidateTLSTrust()

        XCTAssertFalse(viewModel.settings.tlsInspectionEnabled)
        XCTAssertEqual(try makeStore(blob).load().tlsInspectionEnabled, false)
        XCTAssertEqual(sent.commands, [.setTLSInspectionEnabled(false)])
        XCTAssertEqual(viewModel.notice, SettingsPresentation.tlsTurnedOffByTrust)
    }

    /// Con la CA en su sitio no se toca nada **ni se dice nada**: un aviso por cada vuelta a primer
    /// plano convertiría la comprobación en ruido y enseñaría a ignorarla.
    func testARevalidationThatFindsEverythingInOrderChangesNothing() async throws {
        let blob = Blob()
        try makeStore(blob).save(AppSettings(tlsInspectionEnabled: true))
        let sent = Sent()
        let viewModel = makeViewModel(
            blob: blob,
            availability: { .ready },
            send: { command in
                sent.commands.append(command)
                return .ok
            }
        )
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.revalidateTLSTrust()

        XCTAssertTrue(viewModel.settings.tlsInspectionEnabled)
        XCTAssertTrue(sent.commands.isEmpty)
        XCTAssertNil(viewModel.notice)
    }

    /// Con la inspección ya apagada no hay nada que revocar, así que tampoco hay aviso: lo que se
    /// revalida es un permiso en uso, no la CA por deporte.
    func testARevalidationWithInspectionOffSaysNothing() async {
        let viewModel = makeViewModel(availability: { .certificateNotReady })
        await viewModel.refresh()

        await viewModel.revalidateTLSTrust()

        XCTAssertFalse(viewModel.settings.tlsInspectionEnabled)
        XCTAssertNil(viewModel.notice)
    }

    /// Guardar lo descifrado no puede sobrevivir a la inspección que lo produce, y se apaga **antes**:
    /// su comando en caliente corta la grabación incluso para las conexiones que ya están descifrando,
    /// mientras que apagar la inspección solo impide que nazcan terminaciones nuevas.
    func testRevokingAlsoStopsRecordingDecryptedContentAndDoesItFirst() async throws {
        let blob = Blob()
        try makeStore(blob).save(
            AppSettings(tlsInspectionEnabled: true, plaintextPersistenceEnabled: true)
        )
        let sent = Sent()
        let viewModel = makeViewModel(
            blob: blob,
            availability: { .certificateNotReady },
            send: { command in
                sent.commands.append(command)
                return .ok
            }
        )
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.revalidateTLSTrust()

        XCTAssertFalse(viewModel.settings.plaintextPersistenceEnabled)
        XCTAssertFalse(viewModel.settings.tlsInspectionEnabled)
        XCTAssertEqual(
            sent.commands,
            [.setPlaintextPersistenceEnabled(false), .setTLSInspectionEnabled(false)]
        )
    }

    // MARK: - Retención

    func testOpeningTheScreenAppliesTheCapsAndSaysSoOnlyIfItDeletedSomething() async throws {
        try await writeCaptures(3)
        try ageCaptures(byDays: 10)
        try await makeFlow(secondsAfterAnchor: 10)
        let blob = Blob()
        try makeStore(blob).save(AppSettings(retention: .init(maxAge: .oneWeek, maxCaptureSize: .unlimited)))
        let viewModel = makeViewModel(blob: blob)

        await viewModel.refresh()

        // El más nuevo no tiene sucesor, así que nunca envejece: se queda solo.
        XCTAssertEqual(remainingSequences(), [2])
        XCTAssertEqual(viewModel.notice?.role, .accent)
        XCTAssertEqual(viewModel.usage?.captureFileCount, 1)
        XCTAssertEqual(viewModel.usage?.historyFlowCount, 0)
    }

    func testAnAutomaticCleanupWithNothingToDeleteStaysQuiet() async throws {
        try await writeCaptures(2)
        let viewModel = makeViewModel()

        await viewModel.refresh()

        XCTAssertEqual(remainingSequences(), [0, 1])
        XCTAssertNil(viewModel.notice)
    }

    func testChangingACapAppliesItRightAwayAndAnswers() async throws {
        try await writeCaptures(3)
        try ageCaptures(byDays: 10)
        let blob = Blob()
        try makeStore(blob).save(AppSettings(retention: .init(maxAge: .unlimited, maxCaptureSize: .unlimited)))
        let viewModel = makeViewModel(blob: blob)
        await viewModel.refresh()
        XCTAssertEqual(remainingSequences(), [0, 1, 2])

        await viewModel.setRetentionAge(.oneDay)

        XCTAssertEqual(try makeStore(blob).load().retention.maxAge, .oneDay)
        XCTAssertEqual(remainingSequences(), [2])
        XCTAssertEqual(viewModel.notice?.role, .accent)
        XCTAssertEqual(viewModel.activity, .idle)
    }

    func testTheFileBeingRecordedSurvivesTheCaps() async throws {
        try await writeCaptures(3)
        try ageCaptures(byDays: 10)
        let blob = Blob()
        try makeStore(blob).save(AppSettings(retention: .init(maxAge: .oneDay, maxCaptureSize: .unlimited)))
        let viewModel = makeViewModel(blob: blob)
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.refresh()

        // Con el túnel vivo, el fichero abierto es el de secuencia más alta y no se toca nunca.
        XCTAssertTrue(remainingSequences().contains(2))
    }

    func testApplyingTheCapsByHandAnswersEvenWhenThereIsNothingToDelete() async throws {
        try await writeCaptures(1)
        let viewModel = makeViewModel()
        await viewModel.refresh()
        viewModel.dismissNotice()

        await viewModel.applyCapsNow()

        XCTAssertEqual(viewModel.notice?.role, .neutral)
        XCTAssertEqual(viewModel.activity, .idle)
    }

    func testWithBothCapsOffNothingIsDeleted() async throws {
        try await writeCaptures(2)
        try ageCaptures(byDays: 90)
        let blob = Blob()
        try makeStore(blob).save(AppSettings(retention: .init(maxAge: .unlimited, maxCaptureSize: .unlimited)))
        let viewModel = makeViewModel(blob: blob)

        await viewModel.refresh()

        XCTAssertEqual(remainingSequences(), [0, 1])
    }

    /// …**menos el contenido descifrado**, que caduca siempre (ADR 0007). Es la trampa que separa los
    /// dos barridos: quitar los topes de captura no puede llevarse por delante una caducidad que el
    /// usuario nunca pudo desactivar.
    func testDecryptedContentIsSweptEvenWithBothCaptureCapsOff() async throws {
        let blob = Blob()
        try makeStore(blob).save(AppSettings(retention: .init(maxAge: .unlimited, maxCaptureSize: .unlimited)))
        let store = try FlowStore(databaseURL: dbURL, anchor: anchor)
        try await writeExpiredPlaintext(to: store)
        let viewModel = makeViewModel(blob: blob)

        await viewModel.refresh()

        XCTAssertTrue(PlaintextDirectory.files(in: plaintext).isEmpty)
        let remaining = try await store.plaintextChunkCount()
        XCTAssertEqual(remaining, 0)
    }

    /// Un fichero de contenido descifrado con su fila, fechado a `secondsAfterAnchor` del ancla de
    /// estos tests (que está 30 días atrás, así que el instante 1 es contenido de hace 30 días y
    /// `30 * 86 400` es contenido de ahora mismo).
    private func writeExpiredPlaintext(
        to store: FlowStore,
        secondsAfterAnchor: UInt64 = 1
    ) async throws {
        try FileManager.default.createDirectory(at: plaintext, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: 128).write(
            to: plaintext.appendingPathComponent(PlaintextFileName.make(sequence: 0, date: Date()))
        )
        // El flujo se fecha con el trozo: sus filas cuelgan de él en cascada, así que un flujo viejo
        // se llevaría el contenido descifrado por la retención del **historial** y no por la suya.
        let flowID = try await store.upsertFlow(
            PersistenceFixtures.flow(
                remote: ModelFixtures.v4(93, 184, 216, 34),
                firstSeen: secondsAfterAnchor,
                lastSeen: secondsAfterAnchor
            )
        )
        try await store.appendPlaintext(
            [
                PlaintextChunkMeta(
                    timestamp: PersistenceFixtures.uptime(secondsAfterAnchor),
                    direction: .outbound,
                    stream: 0,
                    location: PlaintextLocation(fileSequence: 0, recordOffset: 16),
                    storedLength: 128,
                    originalLength: 128
                )
            ],
            flowID: flowID
        )
    }

    // MARK: - El contenido descifrado (ADR 0007)

    /// El segundo interruptor no se puede encender sin el primero: sin inspección no se descifra
    /// nada, así que guardar lo descifrado no gobernaría nada.
    func testSavingDecryptedContentCannotBeTurnedOnWithoutInspection() async throws {
        let blob = Blob()
        let sent = Sent()
        let viewModel = makeViewModel(blob: blob, send: { command in
            sent.commands.append(command)
            return .ok
        })
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.setPlaintextPersistence(true)

        XCTAssertFalse(viewModel.settings.plaintextPersistenceEnabled)
        XCTAssertEqual(viewModel.notice, SettingsPresentation.plaintextCannotBeEnabled)
        XCTAssertTrue(sent.commands.isEmpty)
        XCTAssertFalse(viewModel.isPlaintextPersistenceEditable)
    }

    func testSavingDecryptedContentIsStoredAndReachesTheLiveSession() async throws {
        let blob = Blob()
        try makeStore(blob).save(AppSettings(tlsInspectionEnabled: true))
        let sent = Sent()
        let viewModel = makeViewModel(blob: blob, send: { command in
            sent.commands.append(command)
            return .ok
        })
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.setPlaintextPersistence(true)

        XCTAssertTrue(viewModel.settings.plaintextPersistenceEnabled)
        XCTAssertTrue(try makeStore(blob).load().plaintextPersistenceEnabled)
        XCTAssertEqual(sent.commands, [.setPlaintextPersistenceEnabled(true)])
        XCTAssertNil(viewModel.notice)
    }

    /// Apagarlo no exige nada, ni siquiera que la inspección siga encendida: revocar el permiso de
    /// guardar lo que uno dice por dentro no puede depender de que otra cosa coopere.
    func testSavingDecryptedContentCanAlwaysBeTurnedOff() async throws {
        let blob = Blob()
        try makeStore(blob).save(
            AppSettings(tlsInspectionEnabled: false, plaintextPersistenceEnabled: true)
        )
        let sent = Sent()
        let viewModel = makeViewModel(blob: blob, send: { command in
            sent.commands.append(command)
            return .ok
        })
        await viewModel.refresh()
        viewModel.tunnelStateDidChange(to: .live)

        XCTAssertTrue(viewModel.isPlaintextPersistenceEditable)
        await viewModel.setPlaintextPersistence(false)

        XCTAssertFalse(viewModel.settings.plaintextPersistenceEnabled)
        XCTAssertFalse(try makeStore(blob).load().plaintextPersistenceEnabled)
        XCTAssertEqual(sent.commands, [.setPlaintextPersistenceEnabled(false)])
    }

    /// Acortar el plazo es lo que hace quien quiere que algo deje de estar guardado **ya**, así que
    /// se aplica en el acto y no en el barrido siguiente.
    func testShorteningTheDecryptedContentAgeAppliesItAtOnce() async throws {
        let blob = Blob()
        let store = try FlowStore(databaseURL: dbURL, anchor: anchor)
        // Contenido de hace dos horas: sobrevive a una semana y no sobrevive a una hora, que es lo
        // que hace visible el cambio de plazo y no el barrido que `refresh` ya hace.
        try await writeExpiredPlaintext(to: store, secondsAfterAnchor: 30 * 86_400 - 7_200)
        try makeStore(blob).save(AppSettings(retention: .init(maxPlaintextAge: .oneWeek)))
        let viewModel = makeViewModel(blob: blob)
        await viewModel.refresh()

        await viewModel.setPlaintextRetentionAge(.oneHour)

        XCTAssertEqual(try makeStore(blob).load().retention.maxPlaintextAge, .oneHour)
        XCTAssertTrue(PlaintextDirectory.files(in: plaintext).isEmpty)
    }

    func testDeletingTheDecryptedContentLeavesTheHistoryAndTheCaptures() async throws {
        try await writeCaptures(2)
        let store = try FlowStore(databaseURL: dbURL, anchor: anchor)
        // Dentro de su plazo: lo que se afirma es el gesto del usuario, no la caducidad.
        try await writeExpiredPlaintext(to: store, secondsAfterAnchor: 30 * 86_400)
        let viewModel = makeViewModel()
        await viewModel.refresh()
        XCTAssertTrue(viewModel.hasPlaintextToClear)

        await viewModel.clearPlaintext()

        XCTAssertTrue(PlaintextDirectory.files(in: plaintext).isEmpty)
        let chunks = try await store.plaintextChunkCount()
        XCTAssertEqual(chunks, 0)
        // Las dos mitades que este gesto existe para no llevarse.
        XCTAssertEqual(remainingSequences(), [0, 1])
        XCTAssertEqual(viewModel.usage?.historyFlowCount, 1)
        XCTAssertEqual(viewModel.notice?.role, .accent)
        XCTAssertFalse(viewModel.hasPlaintextToClear)
        XCTAssertEqual(viewModel.activity, .idle)
    }

    /// Con el túnel vivo, el fichero que la extensión puede estar escribiendo se queda — y el aviso
    /// lo dice, en vez de dejar creer que se fue hasta el último byte.
    func testDeletingWhileMonitoringKeepsTheOpenFileAndSaysSo() async throws {
        let store = try FlowStore(databaseURL: dbURL, anchor: anchor)
        try await writeExpiredPlaintext(to: store, secondsAfterAnchor: 30 * 86_400)
        let viewModel = makeViewModel()
        viewModel.tunnelStateDidChange(to: .live)
        await viewModel.refresh()

        await viewModel.clearPlaintext()

        XCTAssertEqual(PlaintextDirectory.files(in: plaintext).map(\.sequence), [0])
        XCTAssertEqual(viewModel.notice?.role, .accent)
        XCTAssertEqual(
            viewModel.notice?.message.contains("stop monitoring"),
            true
        )
    }

    func testDeletingWithNothingDecryptedIsAnswered() async throws {
        let viewModel = makeViewModel()
        await viewModel.refresh()

        await viewModel.clearPlaintext()

        XCTAssertEqual(viewModel.notice?.role, .neutral)
    }

    // MARK: - Borrarlo todo

    func testClearingEverythingRemovesTheCapturesAndTheHistory() async throws {
        try await writeCaptures(3)
        try await makeFlow(secondsAfterAnchor: 10)
        let viewModel = makeViewModel()
        await viewModel.refresh()

        await viewModel.clearEverything()

        XCTAssertEqual(remainingSequences(), [])
        XCTAssertEqual(viewModel.usage?.historyFlowCount, 0)
        XCTAssertEqual(viewModel.notice?.role, .accent)
        XCTAssertFalse(viewModel.hasAnythingToClear)
    }

    func testClearingEverythingKeepsTheFileBeingRecorded() async throws {
        try await writeCaptures(3)
        let viewModel = makeViewModel()
        viewModel.tunnelStateDidChange(to: .live)
        await viewModel.refresh()

        await viewModel.clearEverything()

        XCTAssertEqual(remainingSequences(), [2])
    }

    func testWithoutAListingNothingIsDeletedWhileMonitoring() async throws {
        try await writeCaptures(2)
        let unreadable = CaptureLibrary(resolvingDirectory: {
            throw CaptureLibraryError.containerUnavailable("group.x")
        })
        let viewModel = makeViewModel(library: unreadable)
        viewModel.tunnelStateDidChange(to: .live)

        await viewModel.clearEverything()

        // Sin listado no se sabe qué fichero está abierto, y borrar a ciegas podría llevárselo.
        XCTAssertEqual(remainingSequences(), [0, 1])
        XCTAssertEqual(viewModel.notice, SettingsPresentation.recordingFileUnknown)
    }

    // MARK: - Fallos del disco

    func testACaptureFolderThatCannotBeReadIsToldAndDoesNotEmptyTheScreen() async throws {
        let unreadable = CaptureLibrary(resolvingDirectory: {
            throw CaptureLibraryError.containerUnavailable("group.x")
        })
        let storage = StorageManager(
            library: unreadable,
            openingStore: { [dbURL, anchor] in try FlowStore(databaseURL: dbURL!, anchor: anchor) },
            plaintextDirectory: plaintext
        )
        let viewModel = makeViewModel(library: unreadable, storage: storage)

        await viewModel.refresh()

        XCTAssertNil(viewModel.usage)
        XCTAssertEqual(viewModel.notice?.role, .warning)
        // Los ajustes sí se leyeron: un disco ilegible no deja la pantalla sin lo que sí se sabe.
        XCTAssertEqual(viewModel.settings, .default)
        XCTAssertEqual(viewModel.activity, .idle)
    }

    // MARK: - Utilidad de guionizado

    /// Lo enviado por el canal de control. Es una clase porque la closure es `@Sendable` y lo que se
    /// afirma es qué comandos salieron y en qué orden.
    private final class Sent: @unchecked Sendable {
        var commands: [ControlCommand] = []
    }
}
