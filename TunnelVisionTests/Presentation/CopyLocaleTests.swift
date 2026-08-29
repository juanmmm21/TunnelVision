import Foundation
import XCTest

/// El locale bajo el que se afirma la copia (M11).
///
/// Este repo tiene una particularidad que obliga a fijarlo: **los tests afirman literalmente el texto
/// que la app enseña**, y la app solo habla inglés. Hasta ahora cada sesión corría con el idioma de
/// quien la lanzaba, así que una afirmación sobre cómo sale un número solo era cierta por casualidad —
/// el español no agrupa los millares de cuatro dígitos y el inglés sí—, y por eso `port 8,080`
/// sobrevivió tres pantallas **con dos tests mirándolo**.
///
/// El pin lo pone el scheme (`project.yml`, `schemes.TunnelVision.test.language`/`region`), que es
/// donde lo ven por igual Xcode, la terminal y la CI. Lo que hace este fichero es que el pin **no
/// pueda desaparecer en silencio**: el `.xcodeproj` está gitignored y se regenera, y perderlo no
/// rompería ningún test — solo volvería a vaciar las afirmaciones que vigilan los números, que es
/// exactamente el fallo que esto cierra.
///
/// Las llamadas de aquí no son copia y no llegan al catálogo: `SWIFT_EMIT_LOC_STRINGS` está solo en el
/// target de la app.
final class CopyLocaleTests: XCTestCase {

    /// Se afirma la **propiedad de la que dependen los tests**, no el identificador del locale: lo
    /// único que esta suite necesita es que los millares se agrupen como los agrupa el inglés. `en_GB`
    /// valdría igual. Lo que no vale es ni el español (agrupa con punto y solo a partir de cinco
    /// dígitos) ni `en_US_POSIX`, que **no agrupa nunca** y por tanto escondería el mismo fallo por el
    /// otro lado — el POSIX sigue siendo el correcto donde el formato es para una máquina y no para
    /// una persona (`CaptureFileName`, `FlowExport`), que es otra cosa.
    func testTheTestsRunUnderTheNumberFormattingTheAppShows() {
        let fourDigits = 1_234

        XCTAssertEqual(
            String(localized: "test.locale.probe.integer", defaultValue: "\(fourDigits)"),
            "1,234",
            """
            el proceso de tests no corre en inglés (Locale.current = \(Locale.current.identifier)), \
            así que toda afirmación sobre cómo sale un número está vacía. Lo fija el scheme en \
            project.yml (schemes.TunnelVision.test.language/region); tras cambiarlo hay que \
            regenerar con `xcodegen generate`.
            """
        )
    }

    /// Y la otra mitad de la regla, que es la que se aplica en las cuatro llamadas que interpolan un
    /// número que **identifica**: envolverlo en `String(...)` elige el camino verbatim (`%@`), donde
    /// ningún locale lo toca. Los dos tests juntos son lo que le da dientes a la regla: sin el de
    /// arriba, este pasaría igual con el envoltorio quitado.
    func testWrappingANumberInAStringIsWhatKeepsItVerbatim() {
        let fourDigits = 1_234

        XCTAssertEqual(
            String(localized: "test.locale.probe.wrapped", defaultValue: "\(String(fourDigits))"),
            "1234"
        )
    }

    /// La otra condición que sostiene las afirmaciones de copia, y que hasta hoy no vigilaba nadie: el
    /// bundle de tests **no lleva catálogo** a propósito, así que toda búsqueda cae al `defaultValue`,
    /// que es el texto que el test lee en el fichero de al lado. El día que entrara uno, las mil
    /// afirmaciones de copia pasarían a leer del catálogo sin que ninguna fallase y sin que nada
    /// avisara: dejarían de significar lo que dicen que significan.
    func testCopyLookupsFallBackToTheEnglishWrittenInTheCode() {
        XCTAssertNil(
            Bundle.main.url(forResource: "Localizable", withExtension: "strings"),
            "entró un catálogo en el bundle de tests: las afirmaciones de copia ya no leen el código"
        )
        XCTAssertEqual(
            String(localized: "test.locale.probe.absent", defaultValue: "written in the Swift"),
            "written in the Swift"
        )
    }
}
