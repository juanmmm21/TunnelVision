import Foundation

// Debug-only como el resto del sembrador.
#if DEBUG

/// El proyecto de auditoría que siembra `-TVSeedFixture`: una app inventada con su allowlist, una
/// **baseline** y una sesión de auditoría ya cerradas, cada una con un tramo de los flujos de la
/// captura sintética.
///
/// Existe para que la pestaña de auditoría se pueda mirar, medir y fotografiar en el Simulator, donde
/// la extensión no corre y por tanto nada etiqueta flujos. Las dos sesiones quedan **cerradas** a
/// propósito: una abierta enseñaría su franja en la Dashboard y cambiaría las fotos de una pantalla
/// que no es ésta, y abrir una es un toque en la app sembrada.
public struct AuditFixture: Sendable {

    /// Una sesión sembrada: qué flujos de la captura lleva y cómo se declara.
    struct Session: Sendable {
        let flows: ClosedRange<Int>
        let draft: AuditSessionDraft
        let start: Date
        let end: Date
        let markers: [(kind: SessionMarkerKind, date: Date)]
    }

    let sessions: [Session]

    /// El identificador de la sesión abierta mientras se escriben sus flujos.
    private final class OpenSession: @unchecked Sendable {
        var id: Int64?
    }

    private let current = OpenSession()

    public static let projectName = "Example Health"

    /// Crea el proyecto y decide qué tramo de los flujos lleva cada sesión: el primer cuarto es la
    /// baseline y el segundo, la auditoría. La otra mitad queda sin sesión, que es lo que le pasa al
    /// tráfico de un dispositivo fuera de una auditoría.
    static func project(
        in store: FlowStore,
        anchor: MonotonicAnchor,
        flows: [FixtureFlow]
    ) async throws -> AuditFixture {
        let project = try await store.createAuditProject(
            AuditProjectDraft(
                name: projectName,
                bundleIdentifier: "com.example.health",
                catalogueVersion: nil,
                allowlist: try [
                    ("api.example-health.com", "Backend"),
                    ("*.cdn.example-health.com", "Static assets"),
                    ("telemetry.example-crash.io", "Crash reporting"),
                ].map { AllowlistEntry(pattern: try DomainPattern(parsing: $0.0), note: $0.1) }
            ),
            at: flows.map { anchor.date(forUptime: $0.record.firstSeen) }.min() ?? anchor.wallClock
        )

        let quarter = flows.count / 4
        // Con menos de cuatro flujos no hay tramos que repartir: el proyecto se siembra sin sesiones.
        guard quarter > 0 else { return AuditFixture(sessions: []) }

        let environment = AuditEnvironment(deviceModel: "iPhone18,3", osVersion: "26.5", toolVersion: "1.0.0 (1)")
        func span(_ range: ClosedRange<Int>) -> (start: Date, end: Date) {
            let slice = flows[range]
            let start = slice.map(\.record.firstSeen).min() ?? 0
            let end = slice.map(\.record.lastSeen).max() ?? start
            return (anchor.date(forUptime: start), anchor.date(forUptime: max(start, end)))
        }

        // La baseline es el tramo que **empezó antes**: se graba sin la app auditada instalada, así
        // que una baseline fechada después de la auditoría contaría el método al revés. Los flujos
        // de la captura no vienen en orden cronológico, y por eso se mira en vez de suponerse.
        let first = 0...(quarter - 1)
        let second = quarter...(2 * quarter - 1)
        let firstIsEarlier = span(first).start <= span(second).start
        let baselineRange = firstIsEarlier ? first : second
        let auditRange = firstIsEarlier ? second : first
        let baseline = span(baselineRange)
        let audit = span(auditRange)
        let auditLength = audit.end.timeIntervalSince(audit.start)

        return AuditFixture(sessions: [
            Session(
                flows: baselineRange,
                draft: AuditSessionDraft(
                    projectID: project.id,
                    kind: .baseline,
                    environment: environment,
                    inspection: InspectionConditions(inspectionEnabled: false, caTrusted: false),
                    notes: ""
                ),
                start: baseline.start,
                end: baseline.end,
                markers: []
            ),
            Session(
                flows: auditRange,
                draft: AuditSessionDraft(
                    projectID: project.id,
                    kind: .audit(AppRelease(version: "2.4.0", build: "187")),
                    environment: environment,
                    inspection: InspectionConditions(inspectionEnabled: true, caTrusted: true),
                    notes: "Fresh install, onboarding to first sync."
                ),
                start: audit.start,
                end: audit.end,
                markers: [
                    (.consentGiven, audit.start.addingTimeInterval(auditLength * 0.25)),
                    (.loggedIn, audit.start.addingTimeInterval(auditLength * 0.5)),
                    (.custom("First sync finished"), audit.start.addingTimeInterval(auditLength * 0.75)),
                ]
            ),
        ])
    }

    /// Abre la sesión cuyo tramo empieza en este flujo, si alguna lo hace.
    func open(before flowIndex: Int, in store: FlowStore) async throws {
        guard let session = sessions.first(where: { $0.flows.lowerBound == flowIndex }) else { return }
        current.id = try await store.startAuditSession(session.draft, at: session.start).id
    }

    /// Cierra la sesión cuyo tramo termina en este flujo, con sus marcadores puestos antes: un
    /// marcador solo se admite sobre una sesión abierta.
    func close(after flowIndex: Int, in store: FlowStore) async throws {
        guard let session = sessions.first(where: { $0.flows.upperBound == flowIndex }),
              let id = current.id
        else {
            return
        }
        for marker in session.markers {
            _ = try await store.addMarker(marker.kind, toSession: id, at: marker.date)
        }
        _ = try await store.endAuditSession(id: id, at: session.end)
        current.id = nil
    }
}

#endif
