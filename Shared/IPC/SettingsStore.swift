import Foundation

public enum SettingsStoreError: Error, Sendable, Equatable {
    /// El almacén compartido del App Group no se pudo abrir (falta el entitlement, o el identificador
    /// no es el que se firmó). No es "no hay ajustes guardados": es que no se sabe dónde mirar.
    case containerUnavailable(String)
    /// Había algo guardado y no es un `AppSettings`. Se distingue de la ausencia a propósito: sin nada
    /// guardado lo correcto son los ajustes de fábrica, mientras que un blob ilegible sí es algo que
    /// contarle al usuario, porque significa que lo que eligió se ha perdido.
    case corruptData(String)
    /// La escritura falló al codificar o al guardar.
    case writeFailed(String)
}

/// Dónde viven los ajustes del usuario, y cómo los ven **los dos procesos**.
///
/// Vive en `Shared/IPC` y no en `Shared/Persistence` porque es un **contrato entre procesos**, como el
/// codec del canal de control y como el layout del ring: la app escribe y la extensión lee, y el único
/// sitio donde ambos ven el mismo tipo es el framework compartido. Lo que lo distingue del canal de
/// control es que esto es la verdad **duradera** —sobrevive a que la extensión muera y a que el
/// dispositivo se apague—, mientras que el canal sirve para aplicar un cambio sobre una sesión viva.
///
/// El soporte es el `UserDefaults` del App Group, que es el mecanismo que Apple documenta justo para
/// esto. Se guarda **un solo valor**, el `AppSettings` entero codificado en JSON, y no una clave por
/// ajuste: así un lector nunca puede ver media escritura —el ajuste nuevo con el viejo al lado— y la
/// versión del blob es una sola cosa.
///
/// Es un `struct Sendable` sin estado, como `LocalCA`: no cachea nada. Cachear los ajustes aquí sería
/// servir en la extensión lo que la app cambió hace un momento, y la extensión los lee **una vez** por
/// sesión precisamente porque quien decide cuándo releer es quien arranca el túnel.
public struct SettingsStore: Sendable {

    /// La clave lleva versión en el nombre. Si algún día el formato cambia de forma que la
    /// decodificación tolerante no baste, la clave nueva deja intacta la vieja en vez de reinterpretar
    /// sus bytes como algo que no son.
    static let key = "settings.v1"

    private let read: @Sendable () throws -> Data?
    private let write: @Sendable (Data) throws -> Void

    /// Sobre el almacén compartido del App Group, que es el que ve la extensión.
    ///
    /// El `UserDefaults` se resuelve **en cada operación** y no se guarda, por lo mismo que
    /// `CaptureLibrary` resuelve su directorio cada vez: el fallo de resolución es el único que esta
    /// clase puede tener por sí sola, y quedarse con el resultado del primer intento dejaría un fallo
    /// temprano pegado a la pantalla para siempre.
    public init(appGroupID: String = AppGroup.identifier) {
        self.read = {
            guard let defaults = UserDefaults(suiteName: appGroupID) else {
                throw SettingsStoreError.containerUnavailable(appGroupID)
            }
            return defaults.data(forKey: Self.key)
        }
        self.write = { data in
            guard let defaults = UserDefaults(suiteName: appGroupID) else {
                throw SettingsStoreError.containerUnavailable(appGroupID)
            }
            defaults.set(data, forKey: Self.key)
        }
    }

    /// Sobre un soporte cualquiera. Es la costura: en el Simulator un `UserDefaults(suiteName:)`
    /// responde para casi cualquier identificador, así que el caso real —una app sin el entitlement del
    /// App Group— no se puede provocar ahí, y sin esto ese camino no tendría test.
    public init(reading: @escaping @Sendable () throws -> Data?, writing: @escaping @Sendable (Data) throws -> Void) {
        self.read = reading
        self.write = writing
    }

    /// Los ajustes guardados.
    ///
    /// **Que no haya nada guardado no es un error**: es el estado normal de una app recién instalada, y
    /// la respuesta honesta son los ajustes de fábrica. Un blob que no se puede decodificar **sí** lo
    /// es, y se propaga en vez de tragarse: significa que lo que el usuario eligió se ha perdido, y eso
    /// se cuenta en la pantalla de Ajustes (donde además la siguiente escritura lo repara).
    public func load() throws -> AppSettings {
        guard let data = try read() else { return .default }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: data)
        } catch {
            throw SettingsStoreError.corruptData(String(describing: error))
        }
    }

    /// Guarda los ajustes enteros. Sustituye el valor anterior: no hay mezcla de campos, por lo mismo
    /// que se guarda un solo blob.
    public func save(_ settings: AppSettings) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(settings)
        } catch {
            throw SettingsStoreError.writeFailed(String(describing: error))
        }
        try write(data)
    }
}
