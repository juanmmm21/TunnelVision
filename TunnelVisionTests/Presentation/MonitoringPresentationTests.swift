import Foundation
import XCTest

/// La copia y las acciones del control de monitorización. Son reglas de UX con consecuencias reales
/// —un usuario que deniega el permiso y se queda sin salida, un diálogo del sistema que aparece en
/// frío—, así que se afirman aquí y no se comprueban a ojo en el Simulator.
final class MonitoringPresentationTests: XCTestCase {

    /// Todos los fallos que el controlador puede dejar en `state`, para recorrerlos exhaustivamente.
    private let allErrors: [TunnelControlError] = [
        .permissionDenied,
        .notInstalled,
        .configurationFailed("system says no"),
        .startFailed("could not start"),
        .notRunning,
        .controlChannelFailed("pipe closed"),
        .malformedResponse,
    ]

    // MARK: - Estados normales

    /// Sin perfil guardado, encender provoca el diálogo del sistema. Es el **único** camino que lo
    /// provoca, y por eso el único que exige la hoja de explicación previa.
    func testOnlyTheStateWithoutAProfileAsksForPrimingFirst() {
        XCTAssertEqual(MonitoringPresentation.forState(.notInstalled).action, .startAfterPriming)
        XCTAssertEqual(MonitoringPresentation.forState(.off).action, .start)
    }

    func testMonitoringOnOffersStoppingAndReadsAsActive() {
        let presentation = MonitoringPresentation.forState(.live)
        XCTAssertEqual(presentation.action, .stop)
        XCTAssertEqual(presentation.role, .accent)
        XCTAssertFalse(presentation.isBusy)
        // La promesa que el usuario tiene que poder leer estando encendido.
        XCTAssertTrue(presentation.detail.contains("stays on this device"))
    }

    /// Mientras el sistema está a lo suyo no hay nada que pulsar: ofrecer un botón que no puede hacer
    /// nada invita a pulsarlo dos veces.
    func testTransitionsAreBusyAndOfferNoButton() {
        for state in [TunnelState.starting, .stopping] {
            let presentation = MonitoringPresentation.forState(state)
            XCTAssertTrue(presentation.isBusy, "\(state) debería enseñar progreso")
            XCTAssertNil(presentation.action, "\(state) no debería ofrecer acción")
            XCTAssertNil(presentation.actionTitle, "\(state) no debería tener botón")
        }
    }

    // MARK: - Fallos

    /// La regla dura de `docs/ux/onboarding-and-consent.md`: nunca un callejón sin salida. Cualquier
    /// fallo, venga de donde venga, ofrece reintentar.
    func testEveryFailureOffersAWayOut() {
        for error in allErrors {
            let presentation = MonitoringPresentation.forState(.failed(error))
            XCTAssertEqual(presentation.action, .retry, "\(error) debería ofrecer reintento")
            XCTAssertEqual(presentation.actionTitle, "Try again")
            XCTAssertEqual(presentation.role, .warning)
            XCTAssertFalse(presentation.title.isEmpty)
            XCTAssertFalse(presentation.detail.isEmpty)
        }
    }

    /// Reintentar tras un fallo **no** repite la hoja de priming: la tarjeta que el usuario está
    /// leyendo ya explica qué hace falta, y volver a explicarlo sería un paso de más justo cuando
    /// quiere salir del error.
    func testRetryingDoesNotAskForPrimingAgain() {
        for error in allErrors {
            XCTAssertNotEqual(MonitoringPresentation.forState(.failed(error)).action, .startAfterPriming)
        }
    }

    /// Una denegación no es una avería: se explica en lenguaje del usuario y sin mensaje de sistema.
    func testADenialIsExplainedWithoutASystemMessage() {
        let presentation = MonitoringPresentation.forState(.failed(.permissionDenied))
        XCTAssertEqual(presentation.title, "Permission needed")
        XCTAssertNil(presentation.diagnostic)
        XCTAssertTrue(presentation.detail.contains("not sent to us or anyone else"))
    }

    // MARK: - La petición que llega del intro (M10)

    /// La regla que justifica que exista un camino aparte: **una petición de encender no se atiende
    /// apagando**. Desde `live` la acción de la pantalla es parar, y reutilizarla aquí haría que
    /// terminar el intro con la monitorización ya en marcha la tumbase.
    func testAStartRequestIsNeverHonouredByStopping() {
        XCTAssertEqual(MonitoringPresentation.forState(.live).action, .stop)
        XCTAssertNil(MonitoringPresentation.forState(.live).startRequestAction)
    }

    /// En una transición no hay nada que pedir: el sistema ya va hacia algún sitio, y empujarlo otra
    /// vez solo puede confundir el estado.
    func testATransitionHasNothingToRequest() {
        for state in [TunnelState.starting, .stopping] {
            XCTAssertNil(MonitoringPresentation.forState(state).startRequestAction, "\(state)")
        }
    }

    /// Lo demás se conserva tal cual, y ahí está el sentido de no duplicar la decisión: quien viene
    /// del intro pasa por la hoja de explicación exactamente cuando lo haría el botón de la pantalla,
    /// así que el diálogo del sistema no puede aparecer en frío por este camino.
    func testAStartRequestFollowsTheSamePathAsTheScreensOwnButton() {
        XCTAssertEqual(MonitoringPresentation.forState(.notInstalled).startRequestAction, .startAfterPriming)
        XCTAssertEqual(MonitoringPresentation.forState(.off).startRequestAction, .start)
        for error in allErrors {
            XCTAssertEqual(
                MonitoringPresentation.forState(.failed(error)).startRequestAction,
                .retry,
                "\(error): desde un fallo, encender es reintentar"
            )
        }
    }

    /// El texto del sistema se conserva, pero **fuera** de la copia principal: la explicación que lee
    /// el usuario nunca es un mensaje de framework (principio 7 de `docs/ux/00-ux-principles.md`).
    func testTheSystemMessageIsKeptAsideAndNeverBecomesTheCopy() {
        let configuration = MonitoringPresentation.forState(.failed(.configurationFailed("system says no")))
        XCTAssertEqual(configuration.diagnostic, "system says no")
        XCTAssertFalse(configuration.detail.contains("system says no"))
        XCTAssertFalse(configuration.title.contains("system says no"))

        let start = MonitoringPresentation.forState(.failed(.startFailed("could not start")))
        XCTAssertEqual(start.diagnostic, "could not start")
        XCTAssertFalse(start.detail.contains("could not start"))
    }

    // MARK: - El peso del control en la pantalla (2026-08-18)

    /// El defecto que encontró usar la app: el control se llevaba media Dashboard **también** con el
    /// túnel encendido, que es cuando la pantalla existe por el gráfico, los contadores y los hosts.
    /// Lo que se afirma es la regla, no el dibujo: mientras el túnel trabaja o va hacia algún sitio, el
    /// control es una franja.
    func testARunningTunnelShrinksTheControlToAStatusStrip() {
        for state in [TunnelState.live, .starting, .stopping] {
            XCTAssertEqual(MonitoringPresentation.forState(state).prominence, .status, "\(state)")
        }
    }

    /// La otra mitad, y la que impide "arreglar" el defecto encogiéndolo todo: cuando hay algo que
    /// ofrecer —encender o salir de un fallo— el control **sigue** siendo la tarjeta grande. Es lo
    /// primero que ofrece una Dashboard vacía.
    func testThereIsSomethingToOfferKeepsTheFullCard() {
        XCTAssertEqual(MonitoringPresentation.forState(.notInstalled).prominence, .offer)
        XCTAssertEqual(MonitoringPresentation.forState(.off).prominence, .offer)
        for error in allErrors {
            XCTAssertEqual(MonitoringPresentation.forState(.failed(error)).prominence, .offer, "\(error)")
        }
    }

    /// La invariante que une las dos anteriores, y la que un estado nuevo no puede romper sin que esto
    /// se entere: una franja **nunca** es el sitio desde el que se enciende. Encender es lo que la
    /// pantalla ofrece, y ofrecerlo en una línea de estado es exactamente el defecto al revés.
    func testAStatusStripNeverCarriesTheOfferToStart() {
        for state in TunnelState.allCasesForPresentation {
            let presentation = MonitoringPresentation.forState(state)
            guard presentation.prominence == .status else { continue }
            XCTAssertNil(presentation.startRequestAction, "\(state): una franja no puede ofrecer encender")
        }
    }

    /// Y la de la otra dirección: una tarjeta grande siempre tiene un botón. Una tarjeta de ese tamaño
    /// sin nada que pulsar es sitio gastado, que es de lo que iba el defecto.
    func testEveryOfferHasSomethingToTap() {
        for state in TunnelState.allCasesForPresentation {
            let presentation = MonitoringPresentation.forState(state)
            guard presentation.prominence == .offer else { continue }
            XCTAssertNotNil(presentation.action, "\(state): una tarjeta sin acción no ofrece nada")
            XCTAssertNotNil(presentation.actionTitle, "\(state)")
        }
    }

    /// Encendido y apagado tienen que distinguirse **sin color**, y en la franja el símbolo va solo:
    /// no lo acompaña la prosa que en la tarjeta decía de qué estado se hablaba.
    func testOnAndOffAreTellableApartWithoutColour() {
        let live = MonitoringPresentation.forState(.live)
        let off = MonitoringPresentation.forState(.off)
        XCTAssertNotEqual(live.systemImage, off.systemImage)
        XCTAssertNotEqual(live.title, off.title)
    }
}

extension TunnelState {

    /// Todos los estados que el control puede tener que pintar, con un fallo de muestra. `TunnelState`
    /// no es `CaseIterable` porque uno de sus casos lleva un error asociado.
    static var allCasesForPresentation: [TunnelState] {
        [.notInstalled, .off, .starting, .live, .stopping, .failed(.permissionDenied)]
    }
}
