import Foundation

/// Dónde quedaron los bytes de un paquete: en qué fichero de captura y en qué posición de ese
/// fichero.
///
/// Existe porque un offset **por sí solo no identifica nada**. `PcapWriter` rota a un fichero nuevo
/// al superar su tope de tamaño, y cada fichero reinicia sus offsets justo detrás de la cabecera
/// global, así que el mismo número apunta a un registro distinto en cada uno. Guardar la pareja es
/// lo que permite que el Flow Inspector y la pantalla de capturas lleguen a los bytes de *ese*
/// paquete y no a los de otra conexión.
///
/// Vive en `Shared/Models` porque la escribe la extensión (que captura) y la lee la app (que
/// enseña), el mismo motivo por el que están aquí `TunnelAddressing` y `MonotonicAnchor`.
public struct CaptureLocation: Sendable, Hashable, Codable {

    /// Secuencia del fichero: el número que `CaptureFileName` pone en su nombre. Es única dentro del
    /// directorio de capturas — el writer arranca por encima de la mayor que ya haya —, así que dos
    /// sesiones distintas no se pisan mientras sus ficheros sigan existiendo.
    public let fileSequence: UInt32

    /// Offset de la cabecera del registro dentro de ese fichero. Nunca vale 0: todo `.pcap` empieza
    /// por su cabecera global, así que el primer registro posible ya está más allá. Esa propiedad es
    /// la que permite representar "sin captura" con un 0 en los formatos de ancho fijo que no
    /// admiten opcionales (el registro del ring y la fila del store).
    public let recordOffset: UInt64

    public init(fileSequence: UInt32, recordOffset: UInt64) {
        self.fileSequence = fileSequence
        self.recordOffset = recordOffset
    }
}
