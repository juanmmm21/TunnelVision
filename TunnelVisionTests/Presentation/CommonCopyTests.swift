import Foundation
import XCTest
import Shared

/// Tests de la copia que no es de ninguna pantalla (M11).
///
/// Lo que se afirma aquí no es lo que dicen tres palabras, sino que **compartirlas sigue siendo
/// estructural**: son una propiedad que leen varias vistas y no un literal repetido que un día alguien
/// reescribe en un sitio y no en los otros. Y que las tres sigan siendo tres cosas distintas: cancelar
/// abandona, cerrar termina, y descartar quita un aviso.
final class CommonCopyTests: XCTestCase {

    private var everyPieceOfCopy: [(where: String, text: String)] {
        [
            ("cancel", CommonCopy.cancel),
            ("done", CommonCopy.done),
            ("dismissNoticeHint", CommonCopy.dismissNoticeHint),
        ]
    }

    /// El fallo característico de la migración al catálogo: una llamada sin `defaultValue` devuelve
    /// **la clave**, y una clave estructural se lee inocentemente en un diff. Estas tres saldrían a la
    /// pantalla en todos los sitios a la vez.
    func testNoCopyIsARawCatalogKey() {
        for piece in everyPieceOfCopy {
            XCTAssertFalse(piece.text.hasPrefix("common."), "\(piece.where): \(piece.text)")
            XCTAssertFalse(piece.text.isEmpty, "\(piece.where) se quedó sin copia")
        }
    }

    /// El otro fallo característico, el que ningún test de contenido ve.
    func testNoCopyCarriesStrayWhitespace() {
        for piece in everyPieceOfCopy {
            XCTAssertFalse(piece.text.contains("  "), "\(piece.where): espacio doble en «\(piece.text)»")
            XCTAssertEqual(
                piece.text.trimmingCharacters(in: .whitespacesAndNewlines),
                piece.text,
                "\(piece.where): sobra espacio en un extremo"
            )
        }
    }

    /// Cancelar y cerrar hacen cosas distintas —una abandona algo pedido, la otra cierra algo ya
    /// hecho— y el sistema las distingue en todos los idiomas. Que colapsaran en una sola palabra
    /// dejaría al usuario sin saber si tocar el botón de una hoja deshace lo que acaba de hacer.
    func testTheThreeSharedWordsStaySeparate() {
        XCTAssertNotEqual(CommonCopy.cancel, CommonCopy.done)
        XCTAssertNotEqual(CommonCopy.cancel, CommonCopy.dismissNoticeHint)
        XCTAssertNotEqual(CommonCopy.done, CommonCopy.dismissNoticeHint)
    }

    /// Lo que aquí se comparte tiene que significar lo mismo en todos los sitios, así que ninguna de
    /// estas tres puede nombrar una pantalla ni depender de qué quede detrás: las cuatro formas de
    /// salir del flujo de la CA son la prueba de lo contrario y por eso viven en su pantalla.
    func testNothingSharedNamesAScreenOrAnOutcome() {
        for piece in everyPieceOfCopy {
            let lowered = piece.text.lowercased()
            for named in ["certificate", "capture", "monitoring", "traffic", "connection"] {
                XCTAssertFalse(lowered.contains(named), "\(piece.where) nombra «\(named)»: es de su pantalla")
            }
        }
    }

    // MARK: - Lo que se quedó fuera a conciencia

    /// Los seis reintentos de la app, cada uno pedido a su pantalla como lo pide la vista.
    private var everyRetry: [(where: String, text: String?)] {
        var retries: [(where: String, text: String?)] = [
            ("monitoring", MonitoringPresentation.forState(.failed(.permissionDenied)).actionTitle),
            (
                "certificateSetup",
                CertificateSetupPresentation.forStage(.unavailable("errSecInteractionNotAllowed")).primary.title
            ),
            (
                "packetDetail",
                PacketBytesPresentation.placeholder(for: .failed(.recordUnreadable("cut short"))).actionTitle
            ),
        ]

        if case .placeholder(let timeline) = TimelinePresentation.content(
            for: HistorySnapshot(state: .failed(.queryFailed("io")))
        ) {
            retries.append(("timeline", timeline.actionTitle))
        }
        if case .placeholder(let inspector) = FlowInspectorPresentation.content(
            state: .failed(.queryFailed("io")), rows: []
        ) {
            retries.append(("flowInspector", inspector.actionTitle))
        }
        if case .placeholder(let captures) = CapturesPresentation.content(
            state: .failed(.notFound(3)), files: []
        ) {
            retries.append(("captures", captures.actionTitle))
        }

        return retries
    }

    /// La decisión que la migración de Captures dejó aplazada hasta tener las seis pantallas delante, y
    /// que se toma aquí: **_Try again_ no entra en `CommonCopy`**. El listón no es decir las mismas
    /// palabras sino significar lo mismo, y detrás de cada uno de estos botones hay una acción distinta
    /// —releer un directorio, reabrir el historial, repetir una consulta de paquetes, mirar otra vez el
    /// llavero, encender el túnel—; qué falló lo dice **el mensaje de la tarjeta**, y el botón solo lo
    /// repite. Seis claves le dejan al traductor decirlas igual o distinto; una sola se lo impediría.
    ///
    /// Lo que sí se afirma es que **hoy coinciden**, que es justo lo que hace tentador fundirlas: el día
    /// que una se reescriba, este test cae y la decisión se vuelve a tomar a conciencia en vez de
    /// derivar sola. Es la misma forma que la de los dos *Packets* de la pantalla de un paquete.
    func testTheSixRetriesStayApartAndStillSayTheSameWords() {
        let retries = everyRetry
        XCTAssertEqual(retries.count, 6, "una pantalla dejó de ofrecer su reintento")

        for retry in retries {
            XCTAssertEqual(retry.text, "Try again", "\(retry.where) dice otra cosa")
        }
    }

    /// Y que ninguno de los seis se haya ido a `CommonCopy` por la puerta de atrás: si algún día se
    /// funden, se hace cambiando el test de arriba y este comentario, no dejando de mirar.
    func testTheRetryIsNotOneOfTheSharedWords() {
        for piece in everyPieceOfCopy {
            XCTAssertNotEqual(piece.text, "Try again", "\(piece.where) es un reintento y es de su pantalla")
        }
    }
}
