import Foundation

/// Por qué tramos ha ido bajando la barra de scrub: el camino de acercamientos del eje temporal.
///
/// El eje arranca cubriendo todo el historial, y con semanas guardadas cada barra son horas: sin una
/// forma de bajar, "salta a un momento" (`docs/ux/screens.md`) se queda en saltar a la tarde de un
/// martes. Acercarse es volver a consultar la actividad con el tramo elegido, que la consulta ya
/// admite (`FlowStore.packetCounts(in:bucketDuration:)`); lo que hace falta decidir —y es lo que este
/// tipo guarda— es **cómo se vuelve atrás**.
///
/// Es una **pila** y no un solo rango porque la salida tiene que ser simétrica con la entrada: se
/// entró tocando tramos cada vez más finos, así que se sale deshaciendo ese camino. Un solo rango
/// obligaría a que la única salida fuese "todo el historial", y desde tres niveles de acercamiento
/// eso es perder de vista el sitio al que se había llegado — justo el callejón sin salida que prohíbe
/// `docs/ux/00-ux-principles.md`.
///
/// Los niveles van del más ancho al más estrecho: cada uno está contenido en el anterior porque nace
/// de una barra del eje que ese anterior dibujó. **La pila no lo comprueba**: quien apila es el view
/// model, que solo ofrece el gesto sobre las barras del eje que se está enseñando
/// (`TimelineActivity.canZoom`). Aquí solo se guarda el camino.
public struct ScrubZoom: Sendable, Equatable {

    /// Los tramos por los que se ha bajado, del más ancho al más estrecho. Vacía = todo el historial.
    public private(set) var levels: [ClosedRange<Date>]

    public init(levels: [ClosedRange<Date>] = []) {
        self.levels = levels
    }

    /// El eje sin acercar, que es con lo que arranca la pantalla.
    public static let wholeHistory = ScrubZoom()

    /// El tramo que el eje está enseñando, o `nil` si abarca todo el historial.
    public var current: ClosedRange<Date>? { levels.last }

    /// Cuántos acercamientos hay apilados.
    public var depth: Int { levels.count }

    public var isZoomed: Bool { !levels.isEmpty }

    /// Si merece la pena ofrecer "todo el historial" además de "atrás". Con un solo nivel apilado no:
    /// desapilar ya lleva ahí, y dos botones para el mismo sitio se leen como dos destinos distintos.
    public var offersFullReset: Bool { levels.count > 1 }

    /// Baja un nivel. El tramo se guarda **absoluto**, igual que el filtro que lo acompaña
    /// (`TimelineDateFilter.interval`): es un trozo concreto del pasado y ninguna recarga lo recalcula.
    public mutating func zoom(into range: ClosedRange<Date>) {
        levels.append(range)
    }

    /// Sube un nivel y devuelve el tramo que pasa a enseñarse, o `nil` si se ha vuelto a todo el
    /// historial. Devolverlo es lo que permite que la lista se acote a lo mismo que el eje enseña sin
    /// que quien llama tenga que volver a preguntar.
    @discardableResult
    public mutating func zoomOut() -> ClosedRange<Date>? {
        guard !levels.isEmpty else { return nil }
        levels.removeLast()
        return levels.last
    }

    /// Vuelve a todo el historial de una vez.
    public mutating func reset() {
        levels.removeAll()
    }
}
