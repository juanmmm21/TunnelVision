import Foundation
import Shared

/// Cuánto sitio le queda a las capturas antes de que los topes de Ajustes se lleven las más antiguas
/// (`docs/development/03-roadmap.md`, paso 10).
///
/// Contesta **la pregunta que la pantalla de capturas no contestaba**: *¿esto me va a llenar el
/// móvil?* El inventario sabe cuántos ficheros hay y cuánto ocupan; Ajustes sabe hasta dónde pueden
/// crecer y cuánto se conservan. Las dos mitades existían desde M9 y **no se hablaban**, así que la
/// comparación —que es justo el dato— se le dejaba al ojo del usuario, con las dos cifras además en
/// pantallas distintas. Aquí se hace la comparación y se enseña el resultado.
///
/// Es puro y sin caso por defecto, como `MonitoringProminence` o `DNSAnswerReading`: un tope nuevo en
/// `RetentionSettings` tiene que elegir qué dice de él esta pantalla, no heredarlo.

/// Cómo va lo que ocupan las capturas contra el tope de tamaño.
public enum CaptureSizeStanding: Sendable, Equatable {

    /// Caben, y sobra sitio. Es el único caso que puede decir cuánto queda libre.
    case within(used: UInt64, limit: UInt64)

    /// Ya ocupan el tope o lo pasan, y la próxima limpieza se llevará las más antiguas para volver a
    /// caber. **No es lo mismo que `within` con cero libre**: ahí no queda nada que decir sobre el
    /// sitio que sobra, y lo que hay que decir es que se va a perder algo.
    case reached(used: UInt64, limit: UInt64)

    /// El tope **no se puede cumplir**: la captura que se está grabando ya pesa por sí sola más que
    /// él, y ésa no se borra nunca (`RetentionPlan.sizeCapUnreachable`). Es el único caso en que la
    /// respuesta a *¿me va a llenar el móvil?* es que sí, y por eso no se colapsa con `reached`.
    case unmeetable(used: UInt64, limit: UInt64)

    /// `RetentionSize.unlimited`: nada las corta por tamaño. Sigue habiendo tope de antigüedad — sin
    /// él esto no sería un `CaptureHeadroom.bounded`.
    case unlimited(used: UInt64)

    public var used: UInt64 {
        switch self {
        case .within(let used, _), .reached(let used, _), .unmeetable(let used, _), .unlimited(let used):
            used
        }
    }

    /// El tope en bytes, o `nil` cuando no lo hay.
    public var limit: UInt64? {
        switch self {
        case .within(_, let limit), .reached(_, let limit), .unmeetable(_, let limit): limit
        case .unlimited: nil
        }
    }

    /// Lo que queda antes de empezar a perder capturas. Solo existe mientras sobre sitio: en los
    /// otros tres casos un cero o un negativo se leerían como una medida cuando son otra historia.
    public var free: UInt64? {
        guard case .within(let used, let limit) = self else { return nil }
        return limit - used
    }

    /// Qué parte del tope está ocupada, entre 0 y 1, o `nil` cuando no hay tope que llenar.
    ///
    /// Se recorta a 1 en vez de dejarse pasar: lo de más allá del tope no se puede dibujar, y una
    /// barra que se sale de su carril no dice "hay de más", dice que el dibujo está roto. Cuánto se
    /// ha pasado lo dicen las cifras.
    public var fill: Double? {
        guard let limit, limit > 0 else { return nil }
        return min(Double(used) / Double(limit), 1)
    }
}

/// Cuándo se va la captura más antigua por el tope de **antigüedad**.
public enum CaptureExpiry: Sendable, Equatable {

    /// Se irá ese día. Viaja como `Date` y no como texto: el huso y el formato son del dispositivo, y
    /// eso lo sabe la vista — la misma regla que en `CaptureFileDisplay.createdAt`.
    case on(Date)

    /// Ya pasaron el corte y se irán en la próxima limpieza. Son las que un usuario que abra Ajustes
    /// va a ver desaparecer, así que decirlo antes es lo contrario de una sorpresa.
    case overdue(count: Int)

    /// Hay tope de antigüedad, pero ninguna captura tiene todavía fecha de caducidad: un fichero no
    /// deja de crecer hasta que aparece el siguiente, así que hasta entonces no hay un instante desde
    /// el que contar (la misma regla con la que `RetentionPlanner` decide a quién borra). Se dice en
    /// vez de esconderse: una fila que aparece y desaparece sin explicación se lee como una avería.
    case undated

    /// `RetentionAge.unlimited`: nada caduca. Es un tope que el usuario ha quitado a propósito, y por
    /// eso se dice — es la mitad de la respuesta a si esto va a llenar el dispositivo.
    case never
}

/// Lo que la pantalla de capturas sabe decir de los topes, entero.
public enum CaptureHeadroom: Sendable, Equatable {

    /// Ni tope de tamaño ni de antigüedad: **nada borra una captura si no la borra el usuario**.
    ///
    /// Es un caso propio y no la suma de `.unlimited` y `.never` porque no se lee sumándolos: dos
    /// mitades diciendo cada una que su tope no existe obligan al usuario a juntar dos negaciones
    /// para llegar a la única frase que importa. Es la comparación hecha, otra vez.
    case unbounded(used: UInt64)

    /// Hay al menos un tope, y cada mitad dice lo suyo. Las dos pueden ser el caso "sin tope", pero
    /// nunca a la vez: eso es `unbounded`.
    case bounded(size: CaptureSizeStanding, expiry: CaptureExpiry)

    /// Lo que ocupan las capturas ahora mismo.
    public var used: UInt64 {
        switch self {
        case .unbounded(let used): used
        case .bounded(let size, _): size.used
        }
    }

    /// Cómo va el inventario del directorio contra los topes guardados.
    ///
    /// - Parameters:
    ///   - files: el listado del directorio, en cualquier orden.
    ///   - settings: los topes que el usuario tiene guardados, tal y como los lee la extensión.
    ///   - now: el instante contra el que se mide la antigüedad.
    ///   - recordingSequence: el fichero que la extensión está escribiendo, si hay alguno
    ///     (`CapturesPresentation.recordingSequence`). No se borra nunca, así que no caduca ni cuenta
    ///     como sitio recuperable.
    public static func reading(
        files: [CaptureFileInfo],
        settings: RetentionSettings,
        now: Date,
        recordingSequence: UInt32?
    ) -> CaptureHeadroom {
        let ordered = files.sorted { $0.sequence < $1.sequence }
        let used = ordered.reduce(UInt64(0)) { $0 + $1.byteCount }

        guard !settings.isUnlimited else { return .unbounded(used: used) }

        // El plan sale de `RetentionPlanner` y no de una cuenta escrita aquí a propósito: es la misma
        // función con la que la app y la extensión deciden a quién borran, así que lo que esta
        // pantalla promete no puede diferir de lo que luego pasa de verdad.
        let plan = RetentionPlanner.plan(
            files: ordered,
            settings: settings,
            now: now,
            recordingSequence: recordingSequence
        )

        return .bounded(
            size: standing(used: used, limit: settings.maxCaptureSize.maxBytes, plan: plan),
            expiry: expiry(
                ordered: ordered,
                maxAge: settings.maxAge.maxAge,
                now: now,
                recordingSequence: recordingSequence
            )
        )
    }

    // MARK: - Interno

    private static func standing(used: UInt64, limit: UInt64?, plan: RetentionPlan) -> CaptureSizeStanding {
        guard let limit else { return .unlimited(used: used) }
        if plan.sizeCapUnreachable { return .unmeetable(used: used, limit: limit) }
        guard used < limit else { return .reached(used: used, limit: limit) }
        return .within(used: used, limit: limit)
    }

    /// Cuándo caduca la más antigua, con **la regla del planificador y no con la fecha del fichero**:
    /// un `.pcap` se sigue engordando hasta que aparece el siguiente, así que lo que fija su
    /// antigüedad es cuándo se cerró — la fecha de su sucesor — y no cuándo se abrió. Fecharlo por la
    /// propia adelantaría la caducidad de tráfico más reciente que el corte.
    private static func expiry(
        ordered: [CaptureFileInfo],
        maxAge: TimeInterval?,
        now: Date,
        recordingSequence: UInt32?
    ) -> CaptureExpiry {
        guard let maxAge else { return .never }

        var dates: [Date] = []
        for (index, file) in ordered.enumerated() where file.sequence != recordingSequence {
            guard index + 1 < ordered.count, let closedAt = ordered[index + 1].createdAt else { continue }
            dates.append(closedAt.addingTimeInterval(maxAge))
        }

        guard let soonest = dates.min() else { return .undated }

        // `<` y no `<=`, que es exactamente el corte del planificador (`closedAt < now - maxAge`): una
        // captura que caduca justo ahora todavía no está en ningún plan de borrado.
        let overdue = dates.filter { $0 < now }.count
        guard overdue == 0 else { return .overdue(count: overdue) }
        return .on(soonest)
    }
}
