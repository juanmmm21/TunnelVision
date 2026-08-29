import Foundation

/// El formateo de números que la UI enseña: volúmenes de datos, velocidades y contadores.
///
/// Se implementa a mano en vez de con `ByteCountFormatter`/`.formatted(.byteCount)` por dos razones,
/// y ninguna es cosmética: (1) el resultado tiene que ser **determinista** para poder afirmarse en un
/// test —los formateadores de Foundation cambian de unidad, de separador decimal y hasta de texto
/// según la configuración regional del dispositivo—, y (2) el eje del gráfico y las fichas de la
/// Dashboard se repintan varias veces por segundo, así que un formateador que decidiese la unidad
/// según el valor de cada instante haría **saltar** la etiqueta entre "999 B/s" y "1 KB/s". Aquí la
/// unidad la elige el valor, pero la regla es fija y conocida.
///
/// Unidades decimales (1 KB = 1000 B), que es la convención de red — la que usan `tcpdump`, los
/// operadores y el propio iOS al hablar de datos móviles.
public enum DisplayFormat {

    private static let unitStep: Double = 1000

    private static let byteUnits = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Un volumen de datos: `"812 B"`, `"1.5 KB"`, `"27 MB"`.
    public static func bytes(_ count: UInt64) -> String {
        let (value, unit) = scaled(Double(count))
        return "\(number(value)) \(unit)"
    }

    /// Una velocidad: `"1.5 KB/s"`. Un valor negativo o no finito se trata como cero, porque una
    /// velocidad imposible en pantalla es peor que un cero honesto.
    public static func rate(bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 B/s" }
        let (value, unit) = scaled(bytesPerSecond)
        return "\(number(value)) \(unit)/s"
    }

    /// Un contador de cosas (paquetes, conexiones), con separador de millares fijo para que no
    /// dependa de la configuración regional: `"1,204"`.
    public static func count(_ value: UInt64) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var grouped = ""
        for (offset, digit) in digits.enumerated() {
            if offset > 0, (digits.count - offset).isMultiple(of: 3) { grouped.append(",") }
            grouped.append(digit)
        }
        return grouped
    }

    /// Cuánto duró algo: `"0.4 s"`, `"12 s"`, `"3 min 20 s"`, `"1 h 05 min"`.
    ///
    /// Se corta en dos unidades porque la fila de una conexión no es un cronómetro: al usuario le
    /// vale el orden de magnitud. Una duración negativa (relojes que se cruzan) o no finita se enseña
    /// como cero, por lo mismo que una velocidad imposible.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 s" }
        if seconds < 1 { return "\(String(format: "%.1f", seconds)) s" }
        if seconds < 60 { return "\(String(format: "%.0f", seconds.rounded(.down))) s" }

        let wholeSeconds = Int(seconds.rounded(.down))
        if wholeSeconds < 3_600 {
            let minutes = wholeSeconds / 60
            let remainder = wholeSeconds % 60
            return remainder == 0 ? "\(minutes) min" : "\(minutes) min \(remainder) s"
        }

        let hours = wholeSeconds / 3_600
        let minutes = (wholeSeconds % 3_600) / 60
        // Los minutos van con cero a la izquierda para que "1 h 05 min" no se lea como "1 h 5 min"
        // en una columna donde la anchura importa.
        return minutes == 0 ? "\(hours) h" : "\(hours) h \(String(format: "%02d", minutes)) min"
    }

    /// Cuándo pasó algo **dentro** de una conexión, contado desde su primer paquete: `"0.004 s"`,
    /// `"12.500 s"`, `"3 min 20 s"`.
    ///
    /// No sirve `duration` aquí: los paquetes de una conexión se separan por milisegundos, y con su
    /// resolución los primeros cien saldrían todos como "0.0 s", que es tanto como no poner nada. Por
    /// encima del minuto sí se delega en ella — a esa escala el milisegundo ya no dice nada—. Un
    /// desfase negativo (un paquete anterior al comienzo que enseña la cabecera) se enseña como cero:
    /// mejor eso que un instante imposible.
    public static func offset(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0.000 s" }
        if seconds < 60 { return String(format: "%.3f s", seconds) }
        return duration(seconds)
    }

    // MARK: - Interno

    /// Escala el valor a la mayor unidad en la que siga siendo ≥ 1.
    private static func scaled(_ value: Double) -> (value: Double, unit: String) {
        var scaled = value
        var index = 0
        while scaled >= unitStep, index < byteUnits.count - 1 {
            scaled /= unitStep
            index += 1
        }
        return (scaled, byteUnits[index])
    }

    /// Un decimal por debajo de 10 y ninguno por encima: mantiene la precisión donde se nota y evita
    /// que la anchura del texto baile al actualizarse. `String(format:)` no localiza el separador,
    /// que es justo lo que se busca aquí.
    private static func number(_ value: Double) -> String {
        // Se decide sobre el valor **ya redondeado** a un decimal, no sobre el crudo: si no, un 9,96
        // saldría como "10.0" —con decimal y por encima del umbral que decía no tenerlo—.
        let oneDecimal = (value * 10).rounded() / 10
        if oneDecimal < 10, oneDecimal != oneDecimal.rounded(.down) {
            return String(format: "%.1f", oneDecimal)
        }
        return String(format: "%.0f", value)
    }
}
