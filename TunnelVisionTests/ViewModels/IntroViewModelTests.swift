import Foundation
import XCTest
@testable import Shared

/// Tests del view model del intro (M10) contra la costura de `SettingsStore`, que es la única forma
/// de provocar los dos fallos que aquí deciden algo: un almacén que no se deja leer (el
/// `containerUnavailable` real exige una app sin el entitlement del App Group, imposible en Simulator)
/// y uno que no se deja escribir.
///
/// Lo que se afirma no es dibujo: **cuándo aparece el intro**, **qué significa saltarlo** y **qué pasa
/// cuando no se puede recordar que se vio**.
@MainActor
final class IntroViewModelTests: XCTestCase {

    /// El blob de ajustes en memoria, igual que en los tests de la pantalla de Ajustes.
    private final class Blob: @unchecked Sendable {
        var data: Data?
        var readError: SettingsStoreError?
        var writeError: SettingsStoreError?
    }

    private func makeStore(_ blob: Blob) -> SettingsStore {
        SettingsStore(
            reading: {
                if let error = blob.readError { throw error }
                return blob.data
            },
            writing: { data in
                if let error = blob.writeError { throw error }
                blob.data = data
            }
        )
    }

    private func store(_ blob: Blob, _ settings: AppSettings) throws {
        blob.data = try JSONEncoder().encode(settings)
    }

    private func saved(_ blob: Blob) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: XCTUnwrap(blob.data))
    }

    // MARK: - La puerta del arranque

    /// Una instalación recién hecha: no hay nada guardado, y eso **es** la señal de que el intro no se
    /// ha visto. No hace falta un centinela aparte porque el valor de fábrica ya lo dice.
    func testAFreshInstallSeesTheIntro() {
        let viewModel = IntroViewModel(store: makeStore(Blob()))
        viewModel.prepare()

        XCTAssertTrue(viewModel.isPresented)
        XCTAssertEqual(viewModel.card, .whatItDoes)
        XCTAssertFalse(viewModel.cannotBeRemembered)
    }

    func testSomebodyWhoHasSeenItDoesNotSeeItAgain() throws {
        let blob = Blob()
        try store(blob, AppSettings(hasSeenIntro: true))

        let viewModel = IntroViewModel(store: makeStore(blob))
        viewModel.prepare()

        XCTAssertFalse(viewModel.isPresented)
    }

    /// No hay forma de distinguir "instalación nueva" de "no sé dónde mirar", y de las dos salidas
    /// posibles solo una es proporcionada: enseñar tres tarjetas a quien ya las vio es una molestia,
    /// no explicarle nunca la VPN a quien no las ha visto le deja sin lo único que le prepara para el
    /// diálogo del sistema.
    func testAnUnreadableStoreShowsTheIntroInsteadOfHidingIt() {
        let blob = Blob()
        blob.readError = .containerUnavailable("group.test")

        let viewModel = IntroViewModel(store: makeStore(blob))
        viewModel.prepare()

        XCTAssertTrue(viewModel.isPresented)
        XCTAssertTrue(viewModel.cannotBeRemembered, "el hecho no se traga: Ajustes lo cuenta")
    }

    /// La raíz se puede volver a montar. Volver a preguntar justo después de **no haber podido**
    /// escribir devolvería el intro a la cara de quien acaba de cerrarlo.
    func testPreparingAgainDoesNotReopenAnIntroAlreadyFinished() {
        let blob = Blob()
        blob.writeError = .writeFailed("read-only")
        let viewModel = IntroViewModel(store: makeStore(blob))

        viewModel.prepare()
        viewModel.skip()
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertTrue(viewModel.cannotBeRemembered)

        viewModel.prepare()
        XCTAssertFalse(viewModel.isPresented, "el intro cerrado no se reabre solo")
    }

    // MARK: - Navegación

    func testTheCardsAdvanceOneByOneAndTheLastOneFinishes() {
        let viewModel = IntroViewModel(store: makeStore(Blob()))
        viewModel.prepare()

        viewModel.performPrimaryAction()
        XCTAssertEqual(viewModel.card, .howItWorks)
        XCTAssertTrue(viewModel.isPresented, "avanzar no termina el intro")

        viewModel.performPrimaryAction()
        XCTAssertEqual(viewModel.card, .yourPrivacy)
        XCTAssertTrue(viewModel.isPresented)

        viewModel.performPrimaryAction()
        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.outcome, .startMonitoring)
    }

    func testSwipingKeepsTheModelAndTheVisibleCardTogether() {
        let viewModel = IntroViewModel(store: makeStore(Blob()))
        viewModel.prepare()

        viewModel.show(.yourPrivacy)
        XCTAssertEqual(viewModel.card, .yourPrivacy)
        // Y desde ahí el botón primario es el de la última tarjeta, no el de la primera.
        XCTAssertEqual(viewModel.presentation.action, .startMonitoring)
    }

    // MARK: - Las dos salidas

    /// Saltar termina el intro **sin pedir nada**. Es lo que lo convierte en una salida de verdad y no
    /// en un rodeo que acaba igual que el camino largo.
    func testSkippingLandsWithoutAskingForAnything() {
        let viewModel = IntroViewModel(store: makeStore(Blob()))
        viewModel.prepare()

        viewModel.skip()

        XCTAssertFalse(viewModel.isPresented)
        XCTAssertEqual(viewModel.outcome, .dismissed)
    }

    /// Saltar **cuenta como visto**, y eso solo es seguro porque Ajustes lo puede volver a pedir. Lo
    /// contrario sería un intro que reaparece en cada arranque hasta que se aguante entero.
    func testSkippingCountsAsSeenBecauseSettingsCanBringItBack() throws {
        let blob = Blob()
        let viewModel = IntroViewModel(store: makeStore(blob))
        viewModel.prepare()

        viewModel.skip()

        XCTAssertTrue(try saved(blob).hasSeenIntro)
        XCTAssertFalse(viewModel.cannotBeRemembered)
    }

    func testFinishingWithStartAlsoCountsAsSeen() throws {
        let blob = Blob()
        let viewModel = IntroViewModel(store: makeStore(blob))
        viewModel.prepare()

        viewModel.show(.yourPrivacy)
        viewModel.performPrimaryAction()

        XCTAssertTrue(try saved(blob).hasSeenIntro)
    }

    /// Terminar el intro no puede llevarse por delante lo que el usuario había elegido: se lee, se
    /// cambia **un** campo y se guarda el blob entero, igual que hace la pantalla de Ajustes.
    func testFinishingKeepsEverythingElseTheUserHadChosen() throws {
        let blob = Blob()
        let chosen = AppSettings(
            tlsInspectionEnabled: true,
            captureEnabled: false,
            captureDetail: .metadataOnly,
            retention: RetentionSettings(maxAge: .oneDay, maxCaptureSize: .megabytes256)
        )
        try store(blob, chosen)

        let viewModel = IntroViewModel(store: makeStore(blob))
        viewModel.replay()
        viewModel.skip()

        var expected = chosen
        expected.hasSeenIntro = true
        XCTAssertEqual(try saved(blob), expected)
    }

    // MARK: - No poder recordarlo

    /// Un intro que se negase a seguir porque no pudo escribir una preferencia sería desproporcionado
    /// —la extensión ya cae a los ajustes de fábrica y arranca igual—, así que el intro termina y lo
    /// que queda es el hecho, para contarlo donde hay a quién contárselo.
    func testAStoreThatCannotBeWrittenDoesNotTrapTheUserInTheIntro() {
        let blob = Blob()
        blob.writeError = .writeFailed("disk full")

        let viewModel = IntroViewModel(store: makeStore(blob))
        viewModel.prepare()
        viewModel.skip()

        XCTAssertFalse(viewModel.isPresented, "no poder recordarlo no puede bloquear")
        XCTAssertEqual(viewModel.outcome, .dismissed)
        XCTAssertTrue(viewModel.cannotBeRemembered)
        XCTAssertNil(blob.data)
    }

    /// Un blob ilegible se **repara** escribiendo encima, que es lo que ya hace la primera escritura
    /// de la pantalla de Ajustes: lo que había no se podía leer, así que no hay nada que conservar, y
    /// dejarlo sin tocar condenaría al intro a volver en cada arranque para siempre.
    func testACorruptBlobIsRepairedInsteadOfCondemningTheIntroToComeBack() throws {
        let blob = Blob()
        blob.data = Data("this is not settings".utf8)

        let viewModel = IntroViewModel(store: makeStore(blob))
        viewModel.prepare()
        XCTAssertTrue(viewModel.isPresented)

        viewModel.skip()

        XCTAssertTrue(try saved(blob).hasSeenIntro)
        XCTAssertFalse(viewModel.cannotBeRemembered)
    }

    // MARK: - Repetirlo desde Ajustes

    /// Es la otra mitad de "saltar cuenta como visto": sin esto, un toque perdería el intro para
    /// siempre, que es justo el callejón sin salida que prohíben los principios de UX.
    func testSettingsCanBringTheIntroBackFromTheFirstCard() throws {
        let blob = Blob()
        try store(blob, AppSettings(hasSeenIntro: true))
        let viewModel = IntroViewModel(store: makeStore(blob))

        viewModel.prepare()
        XCTAssertFalse(viewModel.isPresented)

        viewModel.replay()

        XCTAssertTrue(viewModel.isPresented)
        XCTAssertEqual(viewModel.card, .whatItDoes, "se vuelve a ver entero, no por donde se dejó")
    }

    /// Releerlo a propósito no borra que ya se vio: si la app muere a mitad, el intro no tiene por qué
    /// volver en el arranque siguiente — quien lo pidió ya sabe dónde encontrarlo.
    func testReplayingDoesNotForgetThatItWasAlreadySeen() throws {
        let blob = Blob()
        try store(blob, AppSettings(hasSeenIntro: true))
        let viewModel = IntroViewModel(store: makeStore(blob))

        viewModel.replay()

        XCTAssertTrue(try saved(blob).hasSeenIntro)
    }

    /// Un intro repetido puede volver a pedir encender: es la misma última tarjeta, y negarle el botón
    /// a quien vuelve sería una tarjeta distinta según quién la mire.
    func testAReplayedIntroCanAskToStartAgain() {
        let viewModel = IntroViewModel(store: makeStore(Blob()))

        viewModel.replay()
        viewModel.show(.yourPrivacy)
        viewModel.performPrimaryAction()

        XCTAssertEqual(viewModel.outcome, .startMonitoring)
    }

    // MARK: - El desenlace

    /// Sin consumirlo, un repintado de la raíz volvería a atender el mismo desenlace y le pediría a la
    /// Dashboard un arranque que el usuario pidió una sola vez.
    func testTheOutcomeIsConsumedSoItIsHonouredOnlyOnce() {
        let viewModel = IntroViewModel(store: makeStore(Blob()))
        viewModel.prepare()
        viewModel.show(.yourPrivacy)
        viewModel.performPrimaryAction()

        XCTAssertEqual(viewModel.outcome, .startMonitoring)
        viewModel.acknowledgeOutcome()
        XCTAssertNil(viewModel.outcome)
    }

    /// Cerrar el intro dos veces (el gesto y el `Binding` de la vista al cerrarse) no puede terminar
    /// dos intros ni pisar el desenlace que ya se había decidido.
    func testClosingAnAlreadyClosedIntroChangesNothing() {
        let viewModel = IntroViewModel(store: makeStore(Blob()))
        viewModel.prepare()
        viewModel.show(.yourPrivacy)
        viewModel.performPrimaryAction()

        viewModel.skip()

        XCTAssertEqual(viewModel.outcome, .startMonitoring, "la salida no puede pisar el arranque pedido")
    }
}
