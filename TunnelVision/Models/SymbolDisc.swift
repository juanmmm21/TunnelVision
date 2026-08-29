import CoreGraphics

/// El disco de marca sobre el que va un símbolo: qué lado tiene el glifo y qué diámetro le hace
/// falta al círculo que lo lleva detrás.
///
/// Existe porque en el intro esos dos números eran **dos constantes sueltas** —un símbolo de 44 y un
/// disco de 88— cuya relación estaba escrita solo en un comentario ("el disco crece con el símbolo"),
/// que es exactamente lo que no la sostiene: son dos `@ScaledMetric` independientes, y tocar uno sin
/// acordarse del otro deja el glifo saliéndose de su fondo. Aquí la relación es la afirmación.
///
/// Y la relación no es "el doble porque queda bien". Un glifo de `side` puntos se dibuja dentro de su
/// **caja cuadrada**, así que el círculo que lo contiene entero tiene que cubrir la **diagonal** de
/// esa caja —`side · √2`— y no su lado: un disco de diámetro `side` cortaría las cuatro esquinas del
/// glifo, que es donde viven las asas de un candado o el borde de un globo terráqueo. Ese es el
/// mínimo geométrico; encima va el aire que hace que el disco se lea como fondo y no como recorte.
///
/// Nada de esto tiene valor por defecto, por lo mismo que `MonitoringProminence` y `ScrubCapacity`:
/// quien pinte un disco nuevo tiene que elegir el lado de su glifo a sabiendas, no heredarlo.
public enum SymbolDisc {

    /// Lo que el disco añade a la diagonal del glifo, en proporción a esa diagonal.
    ///
    /// Un cuarto: por debajo el glifo toca el filo y el disco parece que se le ha quedado pequeño, y
    /// por encima el fondo empieza a pesar más que lo que lleva dentro — que es el defecto que este
    /// tipo viene a corregir en el intro, donde el disco se llevaba el 38 % del alto de la tarjeta.
    public static let breathing: CGFloat = 0.25

    /// El diámetro del disco que lleva un glifo de `side` puntos de lado.
    ///
    /// Devuelve `nil` cuando el lado no es un número o no es positivo: un símbolo sin tamaño no es un
    /// símbolo pequeño, es uno que aún no se ha medido, y contestar con un número dibujaría un disco
    /// alrededor de nada.
    public static func diameter(forSymbolOfSide side: CGFloat) -> CGFloat? {
        guard side.isFinite, side > 0 else { return nil }
        return side * 2.0.squareRoot() * (1 + breathing)
    }
}
