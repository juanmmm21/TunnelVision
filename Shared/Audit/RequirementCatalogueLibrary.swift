import Foundation

/// Por qué no hay catálogo para un proyecto.
public enum RequirementCatalogueLibraryError: Error, Sendable, Hashable {
    /// El proyecto nombra un catálogo que esta versión de la app no trae.
    case notBundled(identifier: String)
    case unreadable(identifier: String, reason: String)
    /// El recurso dice llamarse de otra manera que su fichero.
    case identifierMismatch(resource: String, declared: String)
    case invalid(identifier: String, RequirementCatalogueError)
}

/// Los catálogos que vienen con la app. Se leen del bundle de `Shared`: nunca de la red.
public enum RequirementCatalogueLibrary {

    /// El catálogo con el que se evalúa un proyecto que no ha elegido ninguno.
    public static let defaultIdentifier = "tr-03161-1_3.0"

    /// El catálogo de un proyecto: el que nombra o, si no nombra ninguno, el de por defecto.
    ///
    /// Un catálogo nombrado que no está **no** se sustituye por otro: el informe citaría una
    /// versión del documento que no es la que el proyecto dice evaluar.
    public static func catalogue(for project: AuditProject) throws -> RequirementCatalogue {
        try catalogue(identifier: project.catalogueVersion ?? defaultIdentifier)
    }

    public static func catalogue(identifier: String) throws -> RequirementCatalogue {
        guard let url = bundle.url(forResource: identifier, withExtension: "json") else {
            throw RequirementCatalogueLibraryError.notBundled(identifier: identifier)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RequirementCatalogueLibraryError.unreadable(
                identifier: identifier,
                reason: String(describing: error)
            )
        }
        let catalogue: RequirementCatalogue
        do {
            catalogue = try RequirementCatalogue(data: data)
        } catch let error as RequirementCatalogueError {
            throw RequirementCatalogueLibraryError.invalid(identifier: identifier, error)
        }
        guard catalogue.identifier == identifier else {
            throw RequirementCatalogueLibraryError.identifierMismatch(
                resource: identifier,
                declared: catalogue.identifier
            )
        }
        return catalogue
    }

    // `Shared` es un framework, no un paquete: no hay `Bundle.module`, y `Bundle.main` es el de
    // la app o la extensión que lo enlaza. El bundle propio se alcanza por una clase suya.
    private final class BundleToken {}
    private static let bundle = Bundle(for: BundleToken.self)
}
