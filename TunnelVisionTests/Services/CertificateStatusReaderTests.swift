import Foundation
import Security
import Shared
import XCTest

/// Tests del lector del estado de la CA local (M10).
///
/// Se prueban las dos mitades por separado, que es como están escritas: el **lector** contra costuras
/// guionizadas (el llavero y la evaluación de confianza), y la **evaluación de producción** contra
/// `Security` de verdad, donde solo las respuestas negativas se pueden provocar fuera de un dispositivo
/// con el certificado instalado — que son exactamente las que este código tiene que dar hoy.
final class CertificateStatusReaderTests: XCTestCase {

    // MARK: - El lector

    func testNoTrustProbeMeansNotGenerated() async {
        let reader = CertificateStatusReader(trustProbe: { nil }, evaluatingTrust: { _ in .trusted })

        let status = await reader.status()

        XCTAssertEqual(status, CertificateStatus(authority: .notGenerated))
    }

    /// Sin CA no se pregunta por la confianza: no hay certificado del que preguntarla, y la evaluación
    /// no es gratis.
    func testTrustIsNotEvaluatedWhenThereIsNoCA() async {
        let evaluations = CallCounter()
        let reader = CertificateStatusReader(
            trustProbe: { nil },
            evaluatingTrust: { _ in
                evaluations.increment()
                return .trusted
            }
        )

        _ = await reader.status()

        XCTAssertEqual(evaluations.count, 0)
    }

    /// Lo que se evalúa es **la sonda que salió del llavero**, no otra: un lector que preguntara por
    /// una CA distinta contestaría sobre una raíz que no es la que firma.
    func testTheEvaluatedProbeIsTheOneFromTheKeychain() async {
        let probe = Self.probe()
        let seen = ValueBox<TrustProbe>()
        let reader = CertificateStatusReader(
            trustProbe: { probe },
            evaluatingTrust: { candidate in
                seen.value = candidate
                return .notTrusted
            }
        )

        let status = await reader.status()

        XCTAssertEqual(seen.value, probe)
        XCTAssertEqual(status, CertificateStatus(authority: .generated(.notTrusted)))
    }

    func testATrustedRootIsReportedAsGeneratedAndTrusted() async {
        let reader = CertificateStatusReader(trustProbe: { Self.probe() }, evaluatingTrust: { _ in .trusted })

        let status = await reader.status()

        XCTAssertEqual(status, CertificateStatus(authority: .generated(.trusted)))
    }

    /// El caso que existe desde el 2026-08-15: la raíz está en el almacén pero **no habilitada para
    /// TLS**. Sigue sin dejar encender la inspección —eso no cambia—; lo que gana es poder nombrarse,
    /// que es lo que separa "instala el certificado" de "te falta un interruptor".
    func testARootInstalledWithoutFullTrustIsItsOwnAnswerAndStillNotReady() async {
        let reader = CertificateStatusReader(
            trustProbe: { Self.probe() },
            evaluatingTrust: { _ in .installedWithoutFullTrust }
        )

        let status = await reader.status()

        XCTAssertEqual(status, CertificateStatus(authority: .generated(.installedWithoutFullTrust)))
        XCTAssertEqual(CertificateStatusPolicy.availability(status), .certificateNotReady)
    }

    /// Un llavero que no se deja mirar **no** se cuenta como "no hay CA": la distinción es lo que
    /// impide ofrecer generar una nueva encima de la que el usuario ya instaló.
    func testAFailingKeychainIsUnknownAndNotAbsence() async {
        let reader = CertificateStatusReader(
            trustProbe: { throw LocalCAError.keychain(errSecInteractionNotAllowed) },
            evaluatingTrust: { _ in .trusted }
        )

        let status = await reader.status()

        guard case .unknown(let diagnostic) = status.authority else {
            return XCTFail("un llavero ilegible no puede leerse como ausencia de CA: \(status)")
        }
        XCTAssertTrue(diagnostic.contains("keychain"), diagnostic)
        XCTAssertFalse(CertificateStatusPolicy.canGenerate(status))
    }

    /// Nada se cachea: la CA se vuelve a cargar en cada pregunta, que es lo que permite que retirar la
    /// confianza desde los Ajustes de iOS se note sin reiniciar nada.
    func testEveryQueryLooksAgain() async {
        let generated = ValueBox<Bool>()
        generated.value = false
        let reader = CertificateStatusReader(
            trustProbe: { generated.value == true ? Self.probe() : nil },
            evaluatingTrust: { _ in .trusted }
        )

        let before = await reader.status()
        generated.value = true
        let after = await reader.status()

        XCTAssertEqual(before, CertificateStatus(authority: .notGenerated))
        XCTAssertEqual(after, CertificateStatus(authority: .generated(.trusted)))
    }

    func testAvailabilityIsTheStatusRunThroughThePolicy() async {
        let ready = CertificateStatusReader(trustProbe: { Self.probe() }, evaluatingTrust: { _ in .trusted })
        let notReady = CertificateStatusReader(trustProbe: { nil }, evaluatingTrust: { _ in .trusted })

        let readyAvailability = await ready.availability()
        let notReadyAvailability = await notReady.availability()

        XCTAssertEqual(readyAvailability, .ready)
        XCTAssertEqual(notReadyAvailability, .certificateNotReady)
    }

    // MARK: - La evaluación de producción, contra `Security`

    /// Una CA recién generada es perfectamente válida y **nadie la ha instalado**, así que el sistema
    /// no la ancla ni para TLS ni para X.509 básico: las dos preguntas dicen que no. Es la mitad
    /// afirmable en Simulator, y sin este test un evaluador que contestara siempre `notTrusted` pasaría
    /// por bueno.
    func testAFreshlyGeneratedCAIsNotTrustedBySystem() async throws {
        let probe = try await Self.realProbe()

        XCTAssertEqual(SystemCertificateTrust.evaluate(probe), .notTrusted)
    }

    /// **El test que fija el arreglo del 2026-08-15.** La evaluación vieja preguntaba con
    /// `SecPolicyCreateBasicX509` sobre la raíz **sola**, y eso daba un falso positivo con una raíz
    /// instalada sin confianza plena: la app dejaba encender la inspección y el dispositivo se quedaba
    /// sin navegar. Lo que se pregunta ahora es una cadena de dos con el leaf delante, que es lo que se
    /// presentaría en un handshake de verdad. Se afirma **la forma de la pregunta** y no solo su
    /// resultado: evaluar la raíz suelta seguiría dando `notTrusted` aquí, así que el resultado por sí
    /// solo no protege de volver atrás.
    func testTheProbeIsALeafAndItsRootAndNotJustTheRoot() async throws {
        let probe = try await Self.realProbe()

        XCTAssertEqual(probe.chainDER.count, 2)
        XCTAssertEqual(probe.chainDER.first, probe.leafDER)
        XCTAssertEqual(probe.chainDER.last, probe.rootDER)
        XCTAssertNotEqual(probe.leafDER, probe.rootDER)
        XCTAssertEqual(probe.host, TrustProbe.host)
        XCTAssertTrue(probe.host.hasSuffix(".invalid"), "el host de la sonda no puede poder existir")
    }

    /// Y lo que no es un certificado no es "no confío": es "no lo sé". Distinguirlo importa porque una
    /// cadena ilegible es una avería a contar, mientras que una no confiada es el estado normal previo
    /// a instalarla.
    func testBytesThatAreNotACertificateCannotBeEvaluated() {
        let probe = TrustProbe(leafDER: Data([0x00, 0x01, 0x02]), rootDER: Data([0x03]))

        guard case .cannotEvaluate = SystemCertificateTrust.evaluate(probe) else {
            return XCTFail("unos bytes que no son DER X.509 no se pueden evaluar")
        }
    }

    func testEmptyBytesCannotBeEvaluated() {
        let probe = TrustProbe(leafDER: Data(), rootDER: Data())

        guard case .cannotEvaluate = SystemCertificateTrust.evaluate(probe) else {
            return XCTFail("sin certificado no hay confianza que evaluar")
        }
    }

    // MARK: - Sondas

    /// Sonda de mentira para los tests del lector, cuyo evaluador está guionizado: solo tiene que
    /// viajar entera.
    private static func probe() -> TrustProbe {
        TrustProbe(leafDER: Data([0x01]), rootDER: Data([0x02]))
    }

    /// Sonda de verdad, emitida por una CA recién generada, para los tests que hablan con `Security`.
    private static func realProbe() async throws -> TrustProbe {
        let authority = try CertificateAuthority.generate()
        let leaf = try await authority.mintLeaf(forHost: TrustProbe.host)
        return TrustProbe(
            leafDER: leaf.certificateDER,
            rootDER: await authority.exportRootCertificateDER()
        )
    }
}

/// Contador compartido entre una closure `@Sendable` y el test. `@unchecked Sendable` con `NSLock` por
/// lo mismo que en los demás dobles: el estado es un entero y el candado se toma y se suelta dentro de
/// cada operación, sin `await` de por medio.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}

/// Caja para observar (o guionizar) un valor desde una closure `@Sendable`.
private final class ValueBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}
