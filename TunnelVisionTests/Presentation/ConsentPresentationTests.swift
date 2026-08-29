import Foundation
import XCTest

/// La copia de la hoja que precede al diálogo del sistema. Son reglas de consentimiento con
/// consecuencia real —un usuario al que iOS le pide una VPN sin que nadie se lo haya explicado—, así
/// que se afirman aquí y no se comprueban a ojo en el Simulator.
final class ConsentPresentationTests: XCTestCase {

    // MARK: - La regla dura

    /// **Nunca un solo botón.** `docs/ux/onboarding-and-consent.md` exige que siempre haya un camino
    /// para no hacerlo, y que se distinga del que sigue adelante.
    func testTheSheetAlwaysOffersAWayOut() {
        let presentation = ConsentPresentation.vpnPermission
        XCTAssertFalse(presentation.cancelTitle.isEmpty)
        XCTAssertFalse(presentation.confirmTitle.isEmpty)
        XCTAssertNotEqual(presentation.cancelTitle, presentation.confirmTitle)
    }

    /// La salida es "ahora no" y no "cancelar": no se está interrumpiendo nada, se está decidiendo no
    /// encender todavía — y esa puerta tiene que seguir pareciendo abierta.
    func testTheWayOutDoesNotReadAsCancellingSomethingUnderway() {
        XCTAssertEqual(ConsentPresentation.vpnPermission.cancelTitle, "Not now")
    }

    // MARK: - Qué se explica, y cuándo

    /// El titular se sitúa **antes** del diálogo del sistema. Es lo único que impide que la hoja se
    /// lea como si el permiso ya se hubiera dado.
    func testTheSheetPlacesItselfBeforeTheSystemDialog() {
        XCTAssertEqual(ConsentPresentation.vpnPermission.title, "Before iOS asks")
    }

    /// Las tres promesas que responden al susto de la palabra "VPN", y que ninguna traducción puede
    /// dejarse por el camino: es local y no sube nada, iOS enseñará su icono, y se para cuando se
    /// quiera. La primera es la que contesta a por qué una app de red pide algo así.
    func testTheSheetMakesItsThreePromisesBeforeAnythingIsGranted() {
        let message = ConsentPresentation.vpnPermission.message
        XCTAssertTrue(message.contains("not sent to us or anyone else"))
        XCTAssertTrue(message.contains("VPN icon in the status bar"))
        XCTAssertTrue(message.contains("stop"))
    }

    /// La explicación dice lo que va a pasar en cuanto se siga adelante. Sin eso, la hoja sería una
    /// advertencia genérica y el diálogo del sistema seguiría llegando de sorpresa.
    func testTheSheetNamesWhatTheSystemIsAboutToAsk() {
        XCTAssertTrue(
            ConsentPresentation.vpnPermission.message.contains("ask permission to add a VPN configuration")
        )
    }

    /// El botón que sigue adelante no promete el resultado: quien concede es el diálogo del sistema
    /// que viene después, así que llamarlo "Allow" haría creer que el permiso se da aquí.
    func testTheConfirmButtonDoesNotClaimToGrantThePermission() {
        let confirmTitle = ConsentPresentation.vpnPermission.confirmTitle
        XCTAssertEqual(confirmTitle, "Continue")
        XCTAssertFalse(confirmTitle.lowercased().contains("allow"))
    }
}
