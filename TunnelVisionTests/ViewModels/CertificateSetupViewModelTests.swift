import Foundation
import XCTest
@testable import Shared

/// Tests del view model del flujo guiado de la CA (M10), contra las tres costuras que lo rodean: el
/// llavero (crear, leer la raíz, borrar), el almacén de ajustes y el canal de control. El escritor del
/// perfil es **real**, sobre un temporal, porque lo que hay que demostrar de él es que el fichero que
/// queda en disco es el de la raíz que hay ahora mismo.
///
/// Lo que se afirma no es dibujo: **qué se ofrece según lo que se sabe**, **en qué orden se tocan el
/// ajuste y la CA** —apagar la inspección antes de tocarla, y no tocarla si no se pudo apagar— y que
/// comprobar la confianza y no tenerla todavía no es una avería.
@MainActor
final class CertificateSetupViewModelTests: XCTestCase {

    private enum TestError: Error, Equatable {
        case keychain
    }

    /// Lo que ocurre y en qué orden. Existe para un solo test, pero es el que importa más: el orden
    /// entre apagar la inspección y tocar la CA es la regla que evita romper tráfico que funciona.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []

        func append(_ event: String) {
            lock.lock()
            defer { lock.unlock() }
            events.append(event)
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return events
        }
    }

    /// El llavero de mentira. Se comporta como el de verdad en lo que decide algo: generar reemplaza la
    /// raíz anterior y deja la CA sin confiar (nadie ha instalado nada todavía), y borrar la deja sin
    /// existir.
    private final class FakeCA: @unchecked Sendable {
        private let lock = NSLock()
        private let log: EventLog

        private var currentStatus = CertificateStatus(authority: .notGenerated)
        private var root: Data?
        private var generations = 0
        private var removals = 0

        var generateFails = false
        var removeFails = false

        init(log: EventLog) {
            self.log = log
        }

        var status: CertificateStatus {
            lock.lock()
            defer { lock.unlock() }
            return currentStatus
        }

        var rootCertificate: Data? {
            lock.lock()
            defer { lock.unlock() }
            return root
        }

        var generateCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return generations
        }

        var removeCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return removals
        }

        func generate() throws {
            lock.lock()
            defer { lock.unlock() }
            log.append("generate")
            generations += 1
            if generateFails { throw TestError.keychain }
            root = Data([0x30, 0x03, 0x02, 0x01, UInt8(generations)])
            currentStatus = CertificateStatus(authority: .generated(.notTrusted))
        }

        func remove() throws {
            lock.lock()
            defer { lock.unlock() }
            log.append("remove")
            removals += 1
            if removeFails { throw TestError.keychain }
            root = nil
            currentStatus = CertificateStatus(authority: .notGenerated)
        }

        /// El usuario se fue a los Ajustes de iOS, instaló el perfil y activó la confianza plena.
        func userInstalledAndTrustedIt() {
            lock.lock()
            defer { lock.unlock() }
            currentStatus = CertificateStatus(authority: .generated(.trusted))
        }

        func set(_ status: CertificateStatus, root: Data? = nil) {
            lock.lock()
            defer { lock.unlock() }
            currentStatus = status
            self.root = root
        }
    }

    /// El blob de ajustes en memoria, igual que en los tests del intro y de la pantalla de Ajustes.
    private final class Blob: @unchecked Sendable {
        var data: Data?
        var writeError: SettingsStoreError?
    }

    /// La respuesta guionizada del canal de control.
    private final class Channel: @unchecked Sendable {
        private let lock = NSLock()
        private var commands: [ControlCommand] = []
        var response: ControlResponse = .ok
        var failure: (any Error)?

        func send(_ command: ControlCommand) throws -> ControlResponse {
            lock.lock()
            defer { lock.unlock() }
            commands.append(command)
            if let failure { throw failure }
            return response
        }

        var sent: [ControlCommand] {
            lock.lock()
            defer { lock.unlock() }
            return commands
        }
    }

    // MARK: - Montaje

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CertificateSetupTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct Fixture {
        let viewModel: CertificateSetupViewModel
        let ca: FakeCA
        let blob: Blob
        let channel: Channel
        let log: EventLog
        let directory: URL
    }

    private func makeFixture(settings: AppSettings = .default) throws -> Fixture {
        let log = EventLog()
        let ca = FakeCA(log: log)
        let blob = Blob()
        blob.data = try JSONEncoder().encode(settings)
        let channel = Channel()
        let directory = try temporaryDirectory()

        let store = SettingsStore(
            reading: { blob.data },
            writing: { data in
                if let error = blob.writeError { throw error }
                let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
                log.append("saved(\(decoded?.tlsInspectionEnabled == true))")
                blob.data = data
            }
        )

        let viewModel = CertificateSetupViewModel(
            readStatus: { ca.status },
            rootCertificate: { ca.rootCertificate },
            generateCA: { try ca.generate() },
            removeCA: { try ca.remove() },
            exporter: CertificateProfileExporter(directory: directory),
            store: store,
            send: { command in try channel.send(command) }
        )

        return Fixture(viewModel: viewModel, ca: ca, blob: blob, channel: channel, log: log, directory: directory)
    }

    private func saved(_ blob: Blob) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: XCTUnwrap(blob.data))
    }

    // MARK: - La entrada

    /// El paso 0 va delante de crear nada, y leerlo es lo único que abre la puerta.
    func testTheFlowOpensOnTheExplanationAndOnlyThenOffersToCreate() async throws {
        let fixture = try makeFixture()

        await fixture.viewModel.start()
        XCTAssertEqual(fixture.viewModel.stage, .explainTradeOff)

        fixture.viewModel.acknowledgeTradeOff()
        XCTAssertEqual(fixture.viewModel.stage, .generate)
    }

    /// Cada visita vuelve a explicar: la explicación es la puerta de una decisión, no un trámite que se
    /// despacha una vez.
    func testEachVisitExplainsAgain() async throws {
        let fixture = try makeFixture()

        await fixture.viewModel.start()
        fixture.viewModel.acknowledgeTradeOff()
        await fixture.viewModel.start()

        XCTAssertEqual(fixture.viewModel.stage, .explainTradeOff)
    }

    /// Quien ya lo tiene todo hecho aterriza al final, sin volver a pasar por la explicación de algo
    /// que ya decidió.
    func testAnAlreadyTrustedCALandsOnTheLastStage() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))

        await fixture.viewModel.start()

        XCTAssertEqual(fixture.viewModel.stage, .ready)
    }

    /// Con el llavero ilegible no se crea nada: crear reemplaza la clave raíz, y hacerlo a ciegas se
    /// llevaría por delante la CA que el usuario ya instaló.
    func testNothingIsCreatedWhenTheKeychainCouldNotBeRead() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .unknown("errSecInteractionNotAllowed")))

        await fixture.viewModel.start()
        fixture.viewModel.acknowledgeTradeOff()
        await fixture.viewModel.generate()

        XCTAssertEqual(fixture.viewModel.stage, .unavailable("errSecInteractionNotAllowed"))
        XCTAssertEqual(fixture.ca.generateCount, 0)
    }

    // MARK: - Crear

    func testGeneratingMovesToTheInstallSteps() async throws {
        let fixture = try makeFixture()

        await fixture.viewModel.start()
        fixture.viewModel.acknowledgeTradeOff()
        await fixture.viewModel.generate()

        XCTAssertEqual(fixture.ca.generateCount, 1)
        XCTAssertEqual(fixture.viewModel.stage, .installAndTrust)
        XCTAssertEqual(fixture.viewModel.notice, CertificateSetupPresentation.certificateCreated)
        XCTAssertEqual(fixture.viewModel.activity, .idle)
    }

    /// Una generación que falla no deja el flujo avanzado: sigue habiendo que crear la CA, y el aviso
    /// dice que en el dispositivo no ha cambiado nada.
    func testAFailedGenerationChangesNothing() async throws {
        let fixture = try makeFixture()
        fixture.ca.generateFails = true

        await fixture.viewModel.start()
        fixture.viewModel.acknowledgeTradeOff()
        await fixture.viewModel.generate()

        XCTAssertEqual(fixture.viewModel.stage, .generate)
        XCTAssertEqual(fixture.viewModel.notice?.role, .warning)
        XCTAssertNotNil(fixture.viewModel.notice?.diagnostic)
    }

    // MARK: - El perfil

    func testPreparingTheProfileWritesTheCurrentRootToDisk() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.start()
        fixture.viewModel.acknowledgeTradeOff()
        await fixture.viewModel.generate()

        await fixture.viewModel.prepareProfile()

        let url = try XCTUnwrap(fixture.viewModel.profileURL)
        let root = try XCTUnwrap(fixture.ca.rootCertificate)
        XCTAssertEqual(try Data(contentsOf: url), try CertificateProfile.make(rootCertificateDER: root).data)
        XCTAssertNotEqual(fixture.viewModel.notice?.role, .warning)
    }

    /// Soltar el perfil suelta la **petición** de entregarlo y no el fichero: la hoja del sistema puede
    /// seguir leyéndolo mientras se cierra, y de él se encarga la siguiente escritura o el cambio de
    /// CA. Y volver a pedirlo lo vuelve a pedir aunque el fichero sea exactamente el mismo, que es lo
    /// que la pantalla necesita para volver a presentar la hoja.
    func testDismissingTheProfileReleasesTheRequestAndNotTheFile() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.start()
        fixture.viewModel.acknowledgeTradeOff()
        await fixture.viewModel.generate()
        await fixture.viewModel.prepareProfile()
        let url = try XCTUnwrap(fixture.viewModel.profileURL)

        fixture.viewModel.dismissProfile()

        XCTAssertNil(fixture.viewModel.profileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await fixture.viewModel.prepareProfile()

        XCTAssertEqual(fixture.viewModel.profileURL, url)
    }

    /// La CA desapareció entre dos vueltas (otra sesión la rehízo, el llavero dejó de responder). No es
    /// una avería del gesto: ya no hay qué entregar, y el flujo vuelve a donde de verdad está.
    func testAVanishedCAIsNotOfferedForInstallation() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.notTrusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()
        fixture.ca.set(CertificateStatus(authority: .notGenerated), root: nil)

        await fixture.viewModel.prepareProfile()

        XCTAssertNil(fixture.viewModel.profileURL)
        XCTAssertEqual(fixture.viewModel.notice, CertificateSetupPresentation.certificateMissing)
        XCTAssertEqual(fixture.viewModel.stage, .explainTradeOff, "el estado se vuelve a preguntar, no se supone")
    }

    /// Rehacer la CA se lleva el perfil anterior: es el de una raíz que ya no firma nada, y compartirlo
    /// instalaría un ancla inútil que el usuario creería buena.
    func testTheProfileIsDroppedWhenTheCAIsRemade() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.start()
        fixture.viewModel.acknowledgeTradeOff()
        await fixture.viewModel.generate()
        await fixture.viewModel.prepareProfile()
        let previous = try XCTUnwrap(fixture.viewModel.profileURL)

        fixture.viewModel.requestRegenerate()
        await fixture.viewModel.confirm(try XCTUnwrap(fixture.viewModel.confirmation))

        XCTAssertEqual(fixture.ca.generateCount, 2)
        XCTAssertNil(fixture.viewModel.profileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
    }

    // MARK: - Comprobar la confianza

    /// Es la única forma de saber si los pasos 2 y 3 se hicieron: no se observan, se comprueba el
    /// resultado. Y que todavía no haya confianza **no es un fallo**.
    func testCheckingAgainWithoutTrustIsNotAFailure() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.notTrusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()

        await fixture.viewModel.recheckTrust()

        XCTAssertEqual(fixture.viewModel.notice, CertificateSetupPresentation.stillNotTrusted)
        XCTAssertEqual(fixture.viewModel.notice?.role, .neutral)
        XCTAssertEqual(fixture.viewModel.stage, .installAndTrust)
    }

    func testCheckingAgainAfterTrustFinishesTheFlow() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.notTrusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()

        fixture.ca.userInstalledAndTrustedIt()
        await fixture.viewModel.recheckTrust()

        XCTAssertEqual(fixture.viewModel.stage, .ready)
        XCTAssertEqual(fixture.viewModel.notice, CertificateSetupPresentation.nowTrusted)
    }

    // MARK: - Encender

    func testTurningInspectionOnSavesItAndTellsTheLiveSession() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()

        await fixture.viewModel.enableInspection()

        XCTAssertTrue(try saved(fixture.blob).tlsInspectionEnabled)
        XCTAssertEqual(fixture.channel.sent, [.setTLSInspectionEnabled(true)])
        XCTAssertEqual(fixture.viewModel.notice, CertificateSetupPresentation.inspectionTurnedOn)
        XCTAssertEqual(fixture.viewModel.presentation.primary.action, .finish, "encendida, ya no se ofrece encender")
    }

    /// Y no se puede encender desde ninguna otra etapa: solo `ready` puede afirmar que el sistema
    /// confía en la raíz, y encenderla sin eso rompería todos los handshakes contra nuestro leaf.
    func testInspectionCannotBeTurnedOnFromAnyOtherStage() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.notTrusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()

        await fixture.viewModel.enableInspection()

        XCTAssertFalse(try saved(fixture.blob).tlsInspectionEnabled)
        XCTAssertTrue(fixture.channel.sent.isEmpty)
    }

    /// Un ajuste que no se pudo guardar se cuenta y se queda apagado: el interruptor no puede afirmar
    /// una escritura que no ocurrió.
    func testASaveFailureLeavesInspectionOff() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()
        fixture.blob.writeError = .writeFailed("read-only")

        await fixture.viewModel.enableInspection()

        XCTAssertFalse(fixture.viewModel.inspectionEnabled)
        XCTAssertFalse(try saved(fixture.blob).tlsInspectionEnabled)
        XCTAssertEqual(fixture.viewModel.notice?.role, .warning)
    }

    /// Guardado, pero la sesión viva no lo cogió: se dicen las dos cosas, porque tragarse el fallo
    /// dejaría al usuario creyendo que ya está viendo dentro de sus conexiones.
    func testALiveSessionThatRefusesIsReportedAndTheSettingStaysSaved() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()
        fixture.channel.response = .failed("no engine")

        await fixture.viewModel.enableInspection()

        XCTAssertTrue(try saved(fixture.blob).tlsInspectionEnabled)
        XCTAssertEqual(fixture.viewModel.notice, CertificateSetupPresentation.inspectionOnButNotLive("no engine"))
    }

    /// Que el túnel esté parado es la carrera normal con la UI, no una avería: no hay sesión a la que
    /// aplicar nada y el ajuste ya está guardado para la siguiente.
    func testAStoppedTunnelIsNotReportedAsAFailure() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()
        fixture.channel.response = .notRunning

        await fixture.viewModel.enableInspection()

        XCTAssertEqual(fixture.viewModel.notice, CertificateSetupPresentation.inspectionTurnedOn)
    }

    // MARK: - Las dos acciones destructivas

    func testDestructiveActionsAskFirst() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()

        fixture.viewModel.requestRemove()

        XCTAssertEqual(fixture.viewModel.confirmation, CertificateSetupPresentation.remove)
        XCTAssertEqual(fixture.ca.removeCount, 0, "pedir no es hacer")
    }

    func testDestructiveActionsAreNotOfferedWithoutACA() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.start()

        fixture.viewModel.requestRegenerate()
        fixture.viewModel.requestRemove()

        XCTAssertNil(fixture.viewModel.confirmation)
    }

    /// La regla que evita romper tráfico que funciona: **primero** se apaga la inspección, **después**
    /// se toca la CA. Al revés, la extensión seguiría terminando handshakes con una raíz que el
    /// dispositivo ya no ancla.
    func testInspectionIsTurnedOffBeforeTheCAIsTouched() async throws {
        let fixture = try makeFixture(settings: AppSettings(tlsInspectionEnabled: true))
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()

        fixture.viewModel.requestRegenerate()
        await fixture.viewModel.confirm(try XCTUnwrap(fixture.viewModel.confirmation))

        XCTAssertEqual(fixture.log.all, ["saved(false)", "generate"])
        XCTAssertFalse(try saved(fixture.blob).tlsInspectionEnabled)
        XCTAssertEqual(fixture.ca.generateCount, 1)
    }

    /// Y si no se pudo apagar, la CA se queda **exactamente** como estaba. Es la única salida que no
    /// deja al usuario peor que antes de tocar nada.
    func testWhenInspectionCannotBeTurnedOffTheCAIsLeftAlone() async throws {
        let fixture = try makeFixture(settings: AppSettings(tlsInspectionEnabled: true))
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()
        fixture.blob.writeError = .writeFailed("read-only")

        fixture.viewModel.requestRemove()
        await fixture.viewModel.confirm(try XCTUnwrap(fixture.viewModel.confirmation))

        XCTAssertEqual(fixture.ca.removeCount, 0)
        XCTAssertEqual(fixture.ca.generateCount, 0)
        XCTAssertEqual(
            fixture.viewModel.notice,
            CertificateSetupPresentation.inspectionCouldNotBeTurnedOff("writeFailed(\"read-only\")")
        )
        XCTAssertTrue(try saved(fixture.blob).tlsInspectionEnabled, "lo guardado no cambió")
    }

    /// Quitar la CA borra la clave, apaga la inspección, enseña cómo retirar el perfil de los Ajustes
    /// de iOS —la otra mitad, que la app no puede hacer— y devuelve el flujo a su explicación: volver a
    /// encenderla es volver a tomar la misma decisión.
    func testRemovingDeletesTheKeyAndShowsHowToRemoveTheProfile() async throws {
        let fixture = try makeFixture(settings: AppSettings(tlsInspectionEnabled: true))
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()
        fixture.viewModel.acknowledgeTradeOff()

        fixture.viewModel.requestRemove()
        await fixture.viewModel.confirm(try XCTUnwrap(fixture.viewModel.confirmation))

        XCTAssertEqual(fixture.ca.removeCount, 1)
        XCTAssertFalse(try saved(fixture.blob).tlsInspectionEnabled)
        XCTAssertTrue(fixture.viewModel.showsRemovalGuidance)
        XCTAssertEqual(fixture.viewModel.notice, CertificateSetupPresentation.certificateRemoved)
        XCTAssertEqual(fixture.viewModel.stage, .explainTradeOff)
    }

    /// **El orden de verdad de un `confirmationDialog`**, que es el que este flujo no sobrevivía.
    ///
    /// SwiftUI **descarta el diálogo antes** de ejecutar la acción de su botón: el binding de
    /// presentación pasa a `false` —y con él corre `dismissConfirmation()`— y solo entonces se llama
    /// al closure del botón. Una acción que releyera `confirmation` en ese momento encontraría `nil` y
    /// se saldría sin hacer nada **y sin decirlo**, que es exactamente lo que Juan vio en el iPhone el
    /// 2026-08-23: sale el diálogo, se acepta y no pasa nada.
    ///
    /// Los tests de arriba no lo veían porque llamaban a `confirm` en seco, sin el descarte en medio.
    /// Éste lo mete, que es lo único que hacía falta para que el fallo salga en Simulator.
    func testTheWorkStillHappensWhenTheDialogDismissesItselfFirst() async throws {
        let fixture = try makeFixture(settings: AppSettings(tlsInspectionEnabled: true))
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()

        fixture.viewModel.requestRemove()
        let pending = try XCTUnwrap(fixture.viewModel.confirmation)
        // El descarte que hace el propio diálogo al tocar su botón, antes de la acción.
        fixture.viewModel.dismissConfirmation()
        await fixture.viewModel.confirm(pending)

        XCTAssertEqual(fixture.ca.removeCount, 1, "el borrado tiene que ocurrir igual")
        XCTAssertEqual(fixture.viewModel.notice, CertificateSetupPresentation.certificateRemoved)
    }

    /// Lo mismo para la otra acción: son dos botones y el descarte les pasa a los dos.
    func testCreatingANewOneAlsoSurvivesTheDialogDismissingItself() async throws {
        let fixture = try makeFixture(settings: AppSettings(tlsInspectionEnabled: true))
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()

        fixture.viewModel.requestRegenerate()
        let pending = try XCTUnwrap(fixture.viewModel.confirmation)
        fixture.viewModel.dismissConfirmation()
        await fixture.viewModel.confirm(pending)

        XCTAssertEqual(fixture.ca.generateCount, 1)
        XCTAssertEqual(fixture.viewModel.notice, CertificateSetupPresentation.certificateCreated)
    }

    /// Borrar y crear seguido, en la misma visita, no puede dejar dos instrucciones contradictorias.
    ///
    /// Al borrar, la pantalla pasa a explicar cómo retirar el perfil de los Ajustes de iOS; al crear
    /// acto seguido, esa explicación **se va**, porque el perfil nuevo lleva el mismo identificador y
    /// reemplaza al anterior al instalarse. Se quedaban las dos a la vez —*quita el perfil* encima de
    /// *instala este certificado*—, medido en Simulator el 2026-08-23.
    func testCreatingAfterRemovingClearsTheInstructionsForTheOldProfile() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()

        fixture.viewModel.requestRemove()
        await fixture.viewModel.confirm(try XCTUnwrap(fixture.viewModel.confirmation))
        XCTAssertTrue(fixture.viewModel.showsRemovalGuidance)

        fixture.viewModel.acknowledgeTradeOff()
        await fixture.viewModel.generate()

        XCTAssertFalse(
            fixture.viewModel.showsRemovalGuidance,
            "hay un certificado nuevo que instalar: retirar el perfil viejo ya no aplica"
        )
    }

    /// **Una acción destructiva que no se hace tiene que decir por qué.** Si entre pedir la
    /// confirmación y aceptarla deja de constar que hay CA, no se toca nada — eso está bien — pero
    /// callarse deja al usuario con un gesto sin respuesta, que es el mismo defecto que el de arriba
    /// con otra causa.
    func testAConfirmationThatCanNoLongerBeCarriedOutSaysSoInsteadOfGoingQuiet() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()

        fixture.viewModel.requestRemove()
        let pending = try XCTUnwrap(fixture.viewModel.confirmation)
        // La CA desaparece por debajo, y la pantalla se entera al releer el estado.
        fixture.ca.set(CertificateStatus(authority: .notGenerated), root: nil)
        await fixture.viewModel.refresh()

        await fixture.viewModel.confirm(pending)

        XCTAssertEqual(fixture.ca.removeCount, 0, "no hay nada que borrar")
        XCTAssertEqual(fixture.viewModel.notice, CertificateSetupPresentation.nothingToChange)
    }

    func testAFailedRemovalSaysSoAndKeepsTheCertificate() async throws {
        let fixture = try makeFixture()
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        fixture.ca.removeFails = true
        await fixture.viewModel.start()

        fixture.viewModel.requestRemove()
        await fixture.viewModel.confirm(try XCTUnwrap(fixture.viewModel.confirmation))

        XCTAssertEqual(fixture.viewModel.stage, .ready, "el certificado sigue ahí")
        XCTAssertFalse(fixture.viewModel.showsRemovalGuidance, "no hay perfil que retirar todavía")
        XCTAssertEqual(fixture.viewModel.notice?.role, .warning)
    }

    // MARK: - El almacén

    /// Un blob ilegible se repara escribiendo encima, que es lo que ya hacen las otras dos escrituras
    /// del producto: lo que había no se podía leer, así que no hay nada que conservar.
    func testACorruptSettingsBlobIsRepairedByWriting() async throws {
        let fixture = try makeFixture()
        fixture.blob.data = Data("no soy JSON".utf8)
        fixture.ca.set(CertificateStatus(authority: .generated(.trusted)), root: Data([0x30, 0x01]))
        await fixture.viewModel.start()

        await fixture.viewModel.enableInspection()

        XCTAssertTrue(try saved(fixture.blob).tlsInspectionEnabled)
    }

    // MARK: - La salida

    func testFinishingAsksToClose() async throws {
        let fixture = try makeFixture()
        await fixture.viewModel.start()

        await fixture.viewModel.perform(.finish)

        XCTAssertTrue(fixture.viewModel.isFinished)
    }
}
