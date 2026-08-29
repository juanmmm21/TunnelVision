import CTVResolv
import Foundation

/// Los resolvers de DNS que el sistema tiene configurados **ahora mismo**.
///
/// Es la cáscara device-only de `TunnelResolvers` (`Shared/Models`), que es donde vive la decisión
/// de cuáles se pueden anunciar y por qué. Aquí solo se cruza la frontera con C; por eso vive junto
/// a `PacketTunnelProvider` y no entra en el bundle de tests: lo que hay debajo del shim es la
/// configuración real del dispositivo, que un Simulator no puede guionizar.
enum SystemResolvers {

    /// Lo que el sistema contesta, **sin filtrar**, o `nil` si no se pudo preguntar.
    ///
    /// **Para decidir qué anunciar hay que llamarla antes de `setTunnelNetworkSettings`.** Después,
    /// la configuración que lee `res_getservers` ya incluye la del propio túnel, así que estaríamos
    /// anunciándonos lo que acabamos de anunciar — un lazo que se cerraría solo y en silencio.
    ///
    /// Que ese "después" sea inútil para anunciar no lo hace inútil para **mirar**: releerla con el
    /// túnel activo es la medición que dice si los resolvers del interfaz físico siguen siendo
    /// legibles, de la que depende cómo se arregla que un cambio de red deje el DNS apuntando a la
    /// anterior (`ResolverStatus.reportedNow`). Lo único prohibido es que esa lectura vuelva a
    /// `makeNetworkSettings`.
    ///
    /// `nil` y `[]` son cosas distintas y se distinguen a propósito: "no pudimos preguntar" y "el
    /// sistema no tiene resolvers" llevan a decisiones distintas río arriba (`docs/spec/tunnel-provider.md`).
    ///
    /// Devuelve **texto** y no direcciones porque el filtro es de quien decide qué anunciar
    /// (`TunnelResolvers`, en `Shared/Models`, donde está probado): aquí solo se cruza la frontera
    /// con C. Filtrar de paso habría dejado sin poder distinguir "no había ninguno" de "los había y
    /// ninguno se podía anunciar".
    static func reported() -> [String]? {
        let maximum = Int(CTV_RESOLV_MAX_SERVERS)
        let stride = Int(CTV_RESOLV_ADDRESS_LENGTH)
        var buffer = [CChar](repeating: 0, count: maximum * stride)

        let found = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            guard let base = pointer.baseAddress else { return -1 }
            return ctv_copy_system_resolvers(base, Int32(maximum))
        }
        guard found >= 0 else { return nil }

        var texts: [String] = []
        for index in 0..<Int(found) {
            // El hueco viene relleno de ceros y la cadena termina en el primer NUL: se corta ahí a
            // mano porque `String(decoding:as:)` no lo hace, y decodificar el hueco entero dejaría
            // una dirección con cuarenta ceros detrás que ningún parser reconocería.
            let slot = buffer[(index * stride)..<((index + 1) * stride)]
            let bytes = slot.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let text = String(decoding: bytes, as: UTF8.self)
            guard !text.isEmpty else { continue }
            texts.append(text)
        }
        return texts
    }
}
