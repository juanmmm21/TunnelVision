import Foundation
import XCTest
import Shared

/// Tests del almacén de ajustes (M9): el sitio donde la app escribe lo que el usuario decide y la
/// extensión lo lee al arrancar.
///
/// Casi todo corre contra la costura (`init(reading:writing:)`), porque lo que hay que afirmar es cómo
/// se interpreta lo que hay guardado — nada, algo válido, o basura — y eso con un `UserDefaults` real
/// no se puede provocar a voluntad. El round-trip contra un *suite* real está aparte, y es el que
/// demuestra que el soporte de producción hace lo que se le pide.
final class SettingsStoreTests: XCTestCase {

    /// Soporte en memoria: lo que la costura sustituye. Es una clase porque las dos closures del store
    /// comparten el mismo valor guardado.
    private final class Storage: @unchecked Sendable {
        var data: Data?
        var writeCount = 0
        var readError: SettingsStoreError?
        var writeError: SettingsStoreError?
    }

    private func makeStore(_ storage: Storage) -> SettingsStore {
        SettingsStore(
            reading: {
                if let error = storage.readError { throw error }
                return storage.data
            },
            writing: { data in
                if let error = storage.writeError { throw error }
                storage.data = data
                storage.writeCount += 1
            }
        )
    }

    // MARK: - Lectura

    func testNothingStoredReadsAsTheFactoryDefaults() throws {
        // Es el estado de una app recién instalada, no una avería.
        XCTAssertEqual(try makeStore(Storage()).load(), .default)
    }

    func testSavedSettingsComeBack() throws {
        let storage = Storage()
        let store = makeStore(storage)
        let settings = AppSettings(
            tlsInspectionEnabled: true,
            captureEnabled: true,
            captureDetail: .metadataOnly,
            retention: RetentionSettings(maxAge: .oneDay, maxCaptureSize: .unlimited)
        )

        try store.save(settings)

        XCTAssertEqual(try store.load(), settings)
    }

    func testCorruptDataThrowsInsteadOfSilentlyResettingTheUserChoices() {
        let storage = Storage()
        storage.data = Data("no soy JSON".utf8)

        XCTAssertThrowsError(try makeStore(storage).load()) { error in
            guard case .corruptData = error as? SettingsStoreError else {
                return XCTFail("un blob ilegible es \(SettingsStoreError.self).corruptData, no \(error)")
            }
        }
    }

    func testAContainerThatCannotBeOpenedDoesNotReadAsFactoryDefaults() {
        // La diferencia importa: "no hay nada guardado" son los ajustes de fábrica, pero "no sé dónde
        // mirar" no puede pasar por lo mismo, o la pantalla afirmaría que el usuario no ha elegido nada.
        let storage = Storage()
        storage.readError = .containerUnavailable("group.tests")

        XCTAssertThrowsError(try makeStore(storage).load()) { error in
            XCTAssertEqual(error as? SettingsStoreError, .containerUnavailable("group.tests"))
        }
    }

    // MARK: - Escritura

    func testSavingReplacesTheWholeBlobInOneWrite() throws {
        let storage = Storage()
        let store = makeStore(storage)

        try store.save(AppSettings(captureDetail: .metadataOnly))
        try store.save(AppSettings(tlsInspectionEnabled: true))

        // Un solo valor por escritura: así ningún lector puede ver media escritura (el ajuste nuevo con
        // el viejo al lado), que es la razón de guardar el `AppSettings` entero y no una clave por campo.
        XCTAssertEqual(storage.writeCount, 2)
        let loaded = try store.load()
        XCTAssertTrue(loaded.tlsInspectionEnabled)
        XCTAssertEqual(loaded.captureDetail, .fullPayload, "lo anterior se sustituye, no se mezcla")
    }

    func testAWriteThatFailsIsReported() {
        let storage = Storage()
        storage.writeError = .containerUnavailable("group.tests")

        XCTAssertThrowsError(try makeStore(storage).save(.default)) { error in
            XCTAssertEqual(error as? SettingsStoreError, .containerUnavailable("group.tests"))
        }
    }

    // MARK: - Soporte de producción

    func testRoundTripsThroughARealSharedDefaultsSuite() throws {
        let suite = "com.juanmmm21.tunnelvision.tests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = SettingsStore(appGroupID: suite)

        XCTAssertEqual(try store.load(), .default, "un suite estrenado no tiene nada guardado")

        let settings = AppSettings(captureEnabled: false, captureDetail: .metadataOnly)
        try store.save(settings)

        // Un store nuevo sobre el mismo suite: es lo que hace la extensión, que no comparte memoria con
        // la app y solo puede leer lo que quedó guardado.
        XCTAssertEqual(try SettingsStore(appGroupID: suite).load(), settings)
    }
}
