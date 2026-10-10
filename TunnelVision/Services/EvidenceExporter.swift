import Foundation
import Shared

/// Lo que queda de exportar una sesión: el paquete comprimido, listo para compartir, y qué lleva.
public struct EvidenceExportResult: Sendable, Equatable {

    /// El `.zip`. Dentro hay una carpeta con el mismo nombre y, en ella, los ficheros del paquete.
    public let url: URL

    /// Lo que ocupa el `.zip`.
    public let byteCount: UInt64

    /// Los ficheros del paquete, por nombre: los del manifiesto y el manifiesto.
    public let fileNames: [String]

    public let flowCount: Int
    public let findingCount: Int

    /// `capture.json` tal como se escribió. Viaja con el resultado porque es lo que un evaluador no
    /// ve abriendo el zip —cuántos paquetes no llevan bytes y por qué— y la pantalla tiene que
    /// decirlo antes de que el paquete salga del dispositivo.
    public let capture: EvidenceCaptureDocument

    public init(
        url: URL,
        byteCount: UInt64,
        fileNames: [String],
        flowCount: Int,
        findingCount: Int,
        capture: EvidenceCaptureDocument
    ) {
        self.url = url
        self.byteCount = byteCount
        self.fileNames = fileNames
        self.flowCount = flowCount
        self.findingCount = findingCount
        self.capture = capture
    }
}

public enum EvidenceExportError: Error, Sendable, Equatable {

    /// La sesión ya no está en el historial (o su proyecto): se borró con la pantalla abierta.
    case sessionNotFound

    /// La sesión sigue grabando. Un paquete es evidencia cerrada (`EvidenceBundleError`).
    case sessionStillOpen

    /// El proyecto nombra un catálogo que esta versión de la app no trae. No se exporta con otro:
    /// el paquete citaría una versión del documento que no es la que el proyecto dice evaluar.
    case catalogueNotBundled(identifier: String)

    /// El catálogo está en la app pero no se dejó leer.
    case catalogueUnusable(identifier: String)

    /// El historial no respondió.
    case historyUnreadable(HistoryError)

    /// El historial tenía paquetes de un flujo que no estaba entre los que se leyeron: cambió entre
    /// las dos lecturas. Repetir la exportación lo resuelve, y por eso es un caso aparte.
    case historyChangedWhileExporting

    /// No se pudo resolver dónde están las capturas del dispositivo.
    case captureDirectoryUnavailable(String)

    /// La carpeta, un fichero o el `.zip` no se pudieron escribir.
    case writeFailed(String)
}

/// Los nombres de lo que el exportador deja en disco.
public enum EvidenceExportNaming {

    public static let prefix = "tunnelvision-evidence-"
    public static let archiveExtension = "zip"

    /// El nombre de la carpeta del paquete, que es también el de la carpeta **dentro** del zip.
    ///
    /// Lleva el identificador de la sesión y no el nombre del proyecto ni la versión auditada: los
    /// dos son texto libre del evaluador, y un nombre de fichero no es sitio para lo que alguien
    /// tecleó. Qué sesión es lo dice `session.json`.
    public static func folderName(sessionID: Int64, exportedAt date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return "\(prefix)session-\(sessionID)-\(formatter.string(from: date))"
    }

    /// Si un nombre es de algo que escribió el exportador: una carpeta de paquete o su zip.
    public static func isExportName(_ name: String) -> Bool {
        name.hasPrefix(prefix)
    }
}

/// Exporta una sesión de auditoría cerrada como un paquete de evidencia (`docs/spec/audit.md`
/// § *Evidence bundle*): arma los documentos, recorta la captura, escribe el manifiesto el último y
/// lo comprime todo en un `.zip` listo para la hoja de compartir.
///
/// Es quien junta las dos mitades que `Shared` deja sueltas a propósito: `EvidenceBundle`, que es
/// puro, y `EvidenceCaptureWriter`, que es el que toca el historial y el disco.
///
/// Vive en el **temporal de la app**, como el export de conexiones y por lo mismo, y con más
/// motivo: la captura lleva legible lo que viajó en claro, y de una app médica eso pueden ser datos
/// de salud. Hay como mucho **un** paquete a la vez — cada exportación se lleva el anterior — y la
/// carpeta sin comprimir no sobrevive a la exportación: lo que queda es el zip.
///
/// Es un `actor` como `FlowExporter`: escribe en disco, y el disco no se toca desde el hilo
/// principal. Abre el historial en cada exportación, como `AuditLibrary`.
public actor EvidenceExporter {

    private let resolveDirectory: @Sendable () throws -> URL
    private let resolveCaptureDirectory: @Sendable () throws -> URL
    private let openStore: @Sendable () throws -> FlowStore

    /// Sobre directorios concretos. Es lo que usan los tests.
    public init(
        directory: URL,
        captureDirectory: URL,
        openingStore: @escaping @Sendable () throws -> FlowStore
    ) {
        self.init(
            resolvingDirectory: { directory },
            resolvingCaptureDirectory: { captureDirectory },
            openingStore: openingStore
        )
    }

    public init(
        resolvingDirectory: @escaping @Sendable () throws -> URL,
        resolvingCaptureDirectory: @escaping @Sendable () throws -> URL,
        openingStore: @escaping @Sendable () throws -> FlowStore
    ) {
        self.resolveDirectory = resolvingDirectory
        self.resolveCaptureDirectory = resolvingCaptureDirectory
        self.openStore = openingStore
    }

    /// Sobre el temporal de la app, y el historial y las capturas del App Group.
    public init(appGroupID: String = AppGroup.identifier) {
        self.init(
            resolvingDirectory: {
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("EvidenceExports", isDirectory: true)
            },
            resolvingCaptureDirectory: {
                guard let url = CaptureDirectory.url(inAppGroup: appGroupID) else {
                    throw CaptureLibraryError.containerUnavailable(appGroupID)
                }
                return url
            },
            openingStore: { try FlowStore(appGroupID: appGroupID) }
        )
    }

    /// Exporta la sesión y devuelve el zip.
    ///
    /// Un fallo **no deja nada en disco**: ni la carpeta a medias ni un zip. Un paquete al que le
    /// falta un fichero, o cuyo manifiesto no cubre lo que hay al lado, es peor que ninguno — quien
    /// lo recibe no ve un error, ve una evidencia.
    ///
    /// - Parameter exportedWith: la versión de la herramienta que exporta, como la escribe
    ///   `AuditRecordingConditions.toolVersion`.
    /// - Parameter now: el instante que el paquete declara como el de su exportación.
    public func export(
        sessionID: Int64,
        exportedWith: String,
        now: Date = Date()
    ) async throws -> EvidenceExportResult {
        let directory = try prepareDirectory()
        let captureDirectory: URL
        do {
            captureDirectory = try resolveCaptureDirectory()
        } catch {
            throw EvidenceExportError.captureDirectoryUnavailable(String(describing: error))
        }

        let store: FlowStore
        do {
            store = try openStore()
        } catch {
            throw EvidenceExportError.historyUnreadable(HistoryError.classifying(error))
        }
        let bundle = try await bundle(ofSession: sessionID, from: store, exportedWith: exportedWith, now: now)

        let name = EvidenceExportNaming.folderName(sessionID: sessionID, exportedAt: now)
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        let archive = directory.appendingPathComponent(name)
            .appendingPathExtension(EvidenceExportNaming.archiveExtension)

        do {
            let written = try await writeFolder(
                bundle, from: store, captureDirectory: captureDirectory, at: folder
            )
            try Self.compress(folder, into: archive)
            // La carpeta ya está entera dentro del zip: fuera de él solo sería una segunda copia
            // sin comprimir de una captura que puede llevar datos de salud.
            try? FileManager.default.removeItem(at: folder)

            let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return EvidenceExportResult(
                url: archive,
                byteCount: UInt64(max(0, size)),
                fileNames: written.fileNames,
                flowCount: bundle.flows.flows.count,
                findingCount: bundle.findings.findings.count,
                capture: written.capture
            )
        } catch {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: archive)
            throw Self.classifying(error)
        }
    }

    // MARK: - Interno

    /// Lee del historial lo que el paquete necesita y lo arma.
    private func bundle(
        ofSession sessionID: Int64,
        from store: FlowStore,
        exportedWith: String,
        now: Date
    ) async throws -> EvidenceBundle {
        let session: AuditSession
        let project: AuditProject
        let markers: [SessionMarker]
        let flows: [StoredFlow]
        do {
            guard let foundSession = try await store.auditSession(id: sessionID),
                  let foundProject = try await store.auditProject(id: foundSession.projectID)
            else {
                throw EvidenceExportError.sessionNotFound
            }
            // Antes de leer un solo flujo: los de una sesión abierta pueden ser muchos y todavía
            // cambian, y `EvidenceBundle` la rechazaría igualmente después de traerlos todos.
            guard !foundSession.isOpen else { throw EvidenceExportError.sessionStillOpen }
            session = foundSession
            project = foundProject
            markers = try await store.markers(forSession: sessionID)
            // Sin tope: un paquete lista **todos** los flujos de su sesión o no es evidencia de
            // ella. Una sesión cerrada ya no gana flujos, así que una sola lectura los trae todos.
            flows = try await store.flows(inAuditSession: sessionID, limit: .max)
        } catch let error as EvidenceExportError {
            throw error
        } catch {
            throw EvidenceExportError.historyUnreadable(HistoryError.classifying(error))
        }

        let catalogue: RequirementCatalogue
        do {
            catalogue = try RequirementCatalogueLibrary.catalogue(for: project)
        } catch RequirementCatalogueLibraryError.notBundled(let identifier) {
            throw EvidenceExportError.catalogueNotBundled(identifier: identifier)
        } catch {
            throw EvidenceExportError.catalogueUnusable(
                identifier: project.catalogueVersion ?? RequirementCatalogueLibrary.defaultIdentifier
            )
        }

        do {
            return try EvidenceBundle(
                project: project,
                session: session,
                markers: markers,
                flows: flows,
                catalogue: catalogue,
                exportedWith: exportedWith,
                exportedAt: now
            )
        } catch {
            throw Self.classifying(error)
        }
    }

    /// Lo que se escribió en la carpeta del paquete.
    private struct WrittenFolder {
        let fileNames: [String]
        let capture: EvidenceCaptureDocument
    }

    /// Escribe la carpeta: los documentos, la captura con el suyo, y **el manifiesto el último**,
    /// con el digest de los bytes que de verdad se escribieron.
    private func writeFolder(
        _ bundle: EvidenceBundle,
        from store: FlowStore,
        captureDirectory: URL,
        at folder: URL
    ) async throws -> WrittenFolder {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var files = try bundle.documentFiles()
        let capture = try await EvidenceCaptureWriter.write(
            for: bundle, from: store, captureDirectory: captureDirectory, into: folder
        )
        files.append(try capture.documentFile())
        // Después de `capture.json`, que es de donde el informe lee qué lleva la captura, y antes
        // del manifiesto, que lo cubre como a los demás.
        files.append(try Self.reportFile(of: bundle, capture: capture.document))
        for file in files {
            try file.data.write(to: folder.appendingPathComponent(file.name), options: .atomic)
        }

        let manifest = try bundle.manifest(of: files, adding: [capture.entry])
        let manifestFile = try manifest.file()
        try manifestFile.data.write(to: folder.appendingPathComponent(manifestFile.name), options: .atomic)

        return WrittenFolder(
            fileNames: (manifest.files.map(\.name) + [manifestFile.name]).sorted(),
            capture: capture.document
        )
    }

    /// `report.pdf`: lo que dicen los documentos del paquete, compuesto en A4 y dibujado.
    private static func reportFile(
        of bundle: EvidenceBundle,
        capture: EvidenceCaptureDocument
    ) throws -> EvidenceFile {
        let report = try EvidenceReport(bundle: bundle, capture: capture, limits: .bundled)
        let typography = EvidenceReportTypography()
        let layout = EvidenceReportLayout(report: report, geometry: .a4, measuring: typography)
        return EvidenceFile(
            name: EvidenceBundleFormat.reportFileName,
            data: EvidenceReportPDF.data(
                of: layout,
                typography: typography,
                title: report.title,
                creator: "TunnelVision \(bundle.session.exportedWith)"
            )
        )
    }

    /// Comprime la carpeta con el coordinador de ficheros del sistema, que es quien sabe hacer un
    /// zip de una carpeta sin añadir una dependencia.
    ///
    /// El zip que da el coordinador **solo existe mientras dura su bloque**: hay que sacarlo de ahí
    /// antes de volver.
    private static func compress(_ folder: URL, into archive: URL) throws {
        var coordinationError: NSError?
        var moveError: (any Error)?
        var moved = false
        NSFileCoordinator().coordinate(
            readingItemAt: folder, options: .forUploading, error: &coordinationError
        ) { zipped in
            do {
                try FileManager.default.moveItem(at: zipped, to: archive)
                moved = true
            } catch {
                moveError = error
            }
        }
        if let coordinationError {
            throw EvidenceExportError.writeFailed(coordinationError.localizedDescription)
        }
        if let moveError {
            throw EvidenceExportError.writeFailed(moveError.localizedDescription)
        }
        guard moved else {
            throw EvidenceExportError.writeFailed("Couldn't compress \(folder.lastPathComponent).")
        }
    }

    /// Crea el directorio si hace falta y se lleva por delante el paquete anterior, entero o a
    /// medias. Solo borra lo que lleva **nuestro** nombre, como `FlowExporter`.
    private func prepareDirectory() throws -> URL {
        let directory: URL
        do {
            directory = try resolveDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw EvidenceExportError.writeFailed(error.localizedDescription)
        }

        let existing = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for item in existing where EvidenceExportNaming.isExportName(item.lastPathComponent) {
            // Que un borrado falle no impide exportar: lo que se pierde es espacio temporal.
            try? FileManager.default.removeItem(at: item)
        }
        return directory
    }

    /// Traduce lo que lanzan las piezas de `Shared` y el disco, para que por encima de aquí no
    /// viaje un error sin tipar.
    private static func classifying(_ error: any Error) -> EvidenceExportError {
        switch error {
        case let error as EvidenceExportError:
            return error
        case EvidenceBundleError.sessionStillOpen:
            return .sessionStillOpen
        case EvidenceCaptureError.flowNotInBundle:
            return .historyChangedWhileExporting
        case EvidenceCaptureError.destinationUnavailable(let detail),
             EvidenceCaptureError.writeFailed(let detail):
            return .writeFailed(detail)
        case is EvidenceBundleError, is EvidenceManifestError, is EvidenceReportError, is EncodingError:
            // Ninguno puede salir de un historial sano: son las comprobaciones de `Shared` sobre
            // lo que este mismo actor le acaba de dar. Si salen, el paquete no se escribe.
            return .writeFailed(String(describing: error))
        case let error as CocoaError:
            return .writeFailed(error.localizedDescription)
        default:
            return .historyUnreadable(HistoryError.classifying(error))
        }
    }
}
