import CoreGraphics

/// Cuántos tramos cabe ofrecer en el eje de la Timeline, que es una pregunta de **anchura** y no de
/// coste.
///
/// El eje existe para elegir un trozo del pasado con el dedo: se toca un tramo y la lista pasa a
/// enseñar solo lo de ese rato (`ScrubPresentation`). O sea que un tramo **es un objetivo táctil**, y
/// le deben los 44 puntos de la HIG (`TouchTarget.minimum`) igual que se los debe un botón. Con 48
/// tramos —el tope que traía `HistoryPolicy.axisBars`— en un iPhone salían a **14 puntos** cada uno:
/// se dibujaban, pero apuntarlos era puntería fina y el eje se leía como una mancha en vez de como
/// una forma.
///
/// La salida no es dibujar menos de lo que se toca ni tocar más de lo que se dibuja —lo que el dedo
/// aplica tiene que ser lo que el ojo señaló—, sino **pedir menos resolución**: el eje ofrece los
/// tramos que caben, y quien quiera más fino se acerca a uno (`TimelineActivity.canZoom`), que es
/// justo el gesto para el que el eje se construyó.
///
/// Todo esto es puro y vive aquí porque hay que poder afirmarlo: la vista mide su anchura y el lector
/// aplica el número, pero **ninguno de los dos decide**.
public enum ScrubCapacity {

    /// Lo que el eje **no** puede usar del ancho de la pantalla, de fuera hacia dentro: los márgenes
    /// de su tarjeta contra la pantalla, el relleno de esa tarjeta y el del carril hundido en el que
    /// va el gráfico. Y nada más: el eje ya no reserva sitio dentro del dibujo para las etiquetas,
    /// que es lo que costaba otros 84 puntos —casi dos tramos— para fechar peor de lo que fecha el
    /// pie (ver `ScrubBar`).
    public static let horizontalBudget: CGFloat =
        2 * Spacing.card
        + 2 * Spacing.row
        + 2 * Spacing.tight

    /// Los tramos que caben en una pantalla de `width` puntos sin que ninguno baje del mínimo táctil,
    /// o `nil` si esa anchura no dice nada todavía.
    ///
    /// Devuelve `nil` —y no un 1 de reserva— cuando la anchura no es un número, no es positiva o no
    /// da ni para un solo tramo: eso no es una pantalla estrecha, es una pantalla que aún no se ha
    /// medido, y contestar con un número haría que el eje se redibujara con un tramo único antes de
    /// que nadie hubiera mirado. Quien pregunta se queda con lo que tenía.
    public static func intervals(inScreenOfWidth width: CGFloat) -> Int? {
        guard width.isFinite, width > 0 else { return nil }
        let usable = width - horizontalBudget
        guard usable >= TouchTarget.minimum else { return nil }
        return Int((usable / TouchTarget.minimum).rounded(.down))
    }
}
