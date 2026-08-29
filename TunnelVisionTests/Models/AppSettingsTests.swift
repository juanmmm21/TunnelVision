import Foundation
import XCTest
import Shared

/// Tests de los ajustes del usuario (M9): los valores de fábrica, lo que cada opción significa para la
/// captura, y la **decodificación tolerante**, que es la única parte con lógica de verdad.
final class AppSettingsTests: XCTestCase {

    // MARK: - Valores de fábrica

    func testFactoryDefaultsMatchWhatTheExtensionDidBeforeSettingsExisted() {
        let settings = AppSettings.default
        XCTAssertFalse(settings.tlsInspectionEnabled, "la inspección TLS es opt-in (ADR 0003)")
        XCTAssertTrue(settings.captureEnabled)
        XCTAssertEqual(settings.captureDetail, .fullPayload)
        // El `snaplen` de fábrica es el mismo que `PcapWriter.Config` traía por defecto: estrenar los
        // ajustes no cambia por sorpresa lo que ya se venía capturando.
        XCTAssertEqual(settings.captureDetail.snaplen, 262_144)
        // De fábrica el intro no se ha visto, y eso es lo que hace que "no hay nada guardado"
        // signifique "instalación nueva" sin necesidad de un centinela aparte (M10).
        XCTAssertFalse(settings.hasSeenIntro)
    }

    func testRetentionDefaultsToCapsAndNotToUnlimited() {
        // Es la decisión de fondo del módulo: sin topes por defecto, el directorio de capturas crece
        // hasta llenar el dispositivo, que es exactamente lo que pasaba mientras esto no existía.
        XCTAssertFalse(RetentionSettings.default.isUnlimited)
        XCTAssertEqual(RetentionSettings.default.maxAge, .oneWeek)
        XCTAssertEqual(RetentionSettings.default.maxCaptureSize, .gigabyte1)
    }

    // MARK: - Lo que significa cada opción

    func testMetadataOnlyStillFitsTheWorstCaseHeaders() {
        // 40 B de cabecera IPv6 + 60 B de cabecera TCP con todas sus opciones. Si el `snaplen` no las
        // cubriera, "solo metadatos" recortaría justo lo que sirve para interpretar la conexión.
        XCTAssertGreaterThanOrEqual(CaptureDetail.metadataOnly.snaplen, 40 + 60)
        XCTAssertLessThan(CaptureDetail.metadataOnly.snaplen, CaptureDetail.fullPayload.snaplen)
    }

    func testRetentionAgesAreRealCalendarSpans() {
        XCTAssertEqual(RetentionAge.oneDay.maxAge, 86_400)
        XCTAssertEqual(RetentionAge.oneWeek.maxAge, 7 * 86_400)
        XCTAssertEqual(RetentionAge.oneMonth.maxAge, 30 * 86_400)
        XCTAssertNil(RetentionAge.unlimited.maxAge, "sin tope no es un tope enorme: es ninguno")
    }

    func testRetentionSizesAreBytesAndUnlimitedIsAbsent() {
        XCTAssertEqual(RetentionSize.megabytes256.maxBytes, 256 * 1024 * 1024)
        XCTAssertEqual(RetentionSize.gigabyte1.maxBytes, 1024 * 1024 * 1024)
        XCTAssertEqual(RetentionSize.gigabytes4.maxBytes, 4 * 1024 * 1024 * 1024)
        XCTAssertNil(RetentionSize.unlimited.maxBytes)
    }

    func testIsUnlimitedOnlyWhenNeitherCapApplies() {
        XCTAssertTrue(RetentionSettings(maxAge: .unlimited, maxCaptureSize: .unlimited).isUnlimited)
        XCTAssertFalse(RetentionSettings(maxAge: .unlimited, maxCaptureSize: .gigabyte1).isUnlimited)
        XCTAssertFalse(RetentionSettings(maxAge: .oneDay, maxCaptureSize: .unlimited).isUnlimited)
    }

    // MARK: - Codificación

    func testRoundTripsThroughJSON() throws {
        let settings = AppSettings(
            tlsInspectionEnabled: true,
            captureEnabled: false,
            captureDetail: .metadataOnly,
            retention: RetentionSettings(maxAge: .oneMonth, maxCaptureSize: .megabytes256)
        )
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
    }

    func testAMissingFieldKeepsTheOtherChoicesInsteadOfResettingEverything() throws {
        // Es el caso de una versión futura leyendo lo que guardó una anterior. Con la decodificación
        // estricta de `Codable` el blob entero fallaría y el usuario perdería de golpe todo lo elegido.
        let json = Data(#"{"tlsInspectionEnabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertTrue(settings.tlsInspectionEnabled, "lo que sí venía se respeta")
        XCTAssertEqual(settings.captureEnabled, AppSettings.default.captureEnabled)
        XCTAssertEqual(settings.captureDetail, AppSettings.default.captureDetail)
        XCTAssertEqual(settings.retention, AppSettings.default.retention)
    }

    func testAnUnknownChoiceFallsBackToItsFactoryValueWithoutDraggingTheOthers() throws {
        let json = Data(#"{"captureDetail":"quantumEntangled","captureEnabled":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(settings.captureDetail, AppSettings.default.captureDetail)
        XCTAssertFalse(settings.captureEnabled, "el campo de al lado sigue siendo el que se guardó")
    }

    func testRetentionDecodesFieldByFieldToo() throws {
        let json = Data(#"{"retention":{"maxAge":"oneDay"}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(settings.retention.maxAge, .oneDay)
        XCTAssertEqual(settings.retention.maxCaptureSize, RetentionSettings.default.maxCaptureSize)
    }

    /// El caso que la tolerancia se escribió para aguantar, ya ocurrido de verdad: un blob guardado
    /// **antes** de M10 no lleva `hasSeenIntro`, y con la decodificación estricta de `Codable` el
    /// campo nuevo habría borrado de golpe todo lo que el usuario había elegido. Además el valor de
    /// fábrica es el correcto para quien ya venía usando la app: se le enseña el intro una vez, que es
    /// una molestia, y no se le pierde ni un ajuste.
    func testABlobWrittenBeforeTheIntroExistedStillReadsWholeAndOnlyTheNewFieldFallsBack() throws {
        let json = Data(
            #"{"tlsInspectionEnabled":true,"captureEnabled":false,"captureDetail":"metadataOnly","retention":{"maxAge":"oneDay","maxCaptureSize":"megabytes256"}}"#
                .utf8
        )
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertTrue(settings.tlsInspectionEnabled)
        XCTAssertFalse(settings.captureEnabled)
        XCTAssertEqual(settings.captureDetail, .metadataOnly)
        XCTAssertEqual(settings.retention, RetentionSettings(maxAge: .oneDay, maxCaptureSize: .megabytes256))
        XCTAssertFalse(settings.hasSeenIntro)
    }

    func testTheIntroFlagRoundTripsAndDoesNotDragTheOtherFields() throws {
        let json = Data(#"{"hasSeenIntro":true,"captureEnabled":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertTrue(settings.hasSeenIntro)
        XCTAssertFalse(settings.captureEnabled)
        XCTAssertEqual(settings.captureDetail, AppSettings.default.captureDetail)
    }

    func testAnObjectWithNothingRecognisableReadsAsTheFactoryDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"foo":1}"#.utf8))
        XCTAssertEqual(settings, .default)
    }

    // MARK: - Contenido descifrado (ADR 0007)

    /// La decisión del ADR en su forma más corta: inspeccionar y **grabar lo inspeccionado** son dos
    /// actos distintos, y el segundo está apagado de fábrica aunque el primero se encienda.
    func testPersistingPlaintextIsItsOwnSwitchAndIsOffByDefault() {
        XCTAssertFalse(AppSettings.default.plaintextPersistenceEnabled)

        let inspecting = AppSettings(tlsInspectionEnabled: true)
        XCTAssertTrue(inspecting.tlsInspectionEnabled)
        XCTAssertFalse(
            inspecting.plaintextPersistenceEnabled,
            "encender la inspección no puede encender la grabación por su cuenta"
        )
    }

    func testDecryptedContentExpiresSoonerThanTheCapturesAndNeverLater() {
        XCTAssertEqual(RetentionSettings.default.maxPlaintextAge, .oneDay)
        XCTAssertLessThan(
            RetentionSettings.default.maxPlaintextAge.maxAge,
            RetentionAge.oneWeek.maxAge ?? .infinity,
            "una semana de .pcap y una semana de plaintext no son el mismo objeto"
        )
    }

    /// La ausencia **es** la decisión: no hay forma de pedir que el contenido descifrado se guarde
    /// para siempre. Si algún día apareciera un caso nuevo, este test es el que obliga a volver al ADR.
    func testDecryptedContentHasNoUnlimitedOption() {
        XCTAssertEqual(PlaintextRetentionAge.allCases, [.oneHour, .oneDay, .oneWeek])
        for age in PlaintextRetentionAge.allCases {
            XCTAssertGreaterThan(age.maxAge, 0)
        }
        XCTAssertEqual(PlaintextRetentionAge.oneHour.maxAge, 3_600)
        XCTAssertEqual(PlaintextRetentionAge.oneDay.maxAge, 86_400)
        XCTAssertEqual(PlaintextRetentionAge.oneWeek.maxAge, 7 * 86_400)
    }

    /// El techo que el usuario no puede subir. Está en el código y no en la pantalla a propósito, así
    /// que lo que un test puede afirmar es que existe y que es un tope de verdad.
    func testThereIsACeilingTheUserCannotRaise() {
        XCTAssertEqual(RetentionSettings.plaintextByteCeiling, 512 * 1024 * 1024)
    }

    /// `isUnlimited` habla del historial y de las capturas, y **no** del contenido descifrado, que
    /// siempre caduca. Quien lo use para saltarse un barrido entero tiene que preguntar aparte.
    func testUnlimitedDoesNotSpeakForDecryptedContent() {
        let settings = RetentionSettings(maxAge: .unlimited, maxCaptureSize: .unlimited)
        XCTAssertTrue(settings.isUnlimited)
        XCTAssertEqual(settings.maxPlaintextAge, .oneDay)
    }

    /// El mismo caso que ya ocurrió con `hasSeenIntro`, ahora con el interruptor nuevo: un blob
    /// escrito antes del ADR 0007 se sigue leyendo entero, y el campo que falta cae a `false` — que es
    /// el valor correcto, porque nadie debe empezar a grabar contenido descifrado por actualizar.
    func testABlobWrittenBeforeTheDecisionDoesNotStartRecording() throws {
        let json = Data(
            #"{"tlsInspectionEnabled":true,"captureEnabled":true,"hasSeenIntro":true,"retention":{"maxAge":"oneWeek","maxCaptureSize":"gigabyte1"}}"#
                .utf8
        )
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertTrue(settings.tlsInspectionEnabled)
        XCTAssertTrue(settings.hasSeenIntro)
        XCTAssertFalse(settings.plaintextPersistenceEnabled)
        XCTAssertEqual(settings.retention.maxPlaintextAge, .oneDay, "y su retención cae al día de fábrica")
    }

    func testThePlaintextAgeRoundTripsAndDecodesOnItsOwn() throws {
        let settings = AppSettings(
            plaintextPersistenceEnabled: true,
            retention: RetentionSettings(maxAge: .oneMonth, maxCaptureSize: .gigabytes4, maxPlaintextAge: .oneHour)
        )
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)

        let partial = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"retention":{"maxPlaintextAge":"oneWeek"}}"#.utf8)
        )
        XCTAssertEqual(partial.retention.maxPlaintextAge, .oneWeek)
        XCTAssertEqual(partial.retention.maxAge, RetentionSettings.default.maxAge)
    }

    func testAnUnknownPlaintextAgeFallsBackToTheFactoryValue() throws {
        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"retention":{"maxPlaintextAge":"forever","maxAge":"oneDay"}}"#.utf8)
        )

        XCTAssertEqual(settings.retention.maxPlaintextAge, .oneDay, "y desde luego no 'para siempre'")
        XCTAssertEqual(settings.retention.maxAge, .oneDay)
    }
}
