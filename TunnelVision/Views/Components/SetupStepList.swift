import SwiftUI

/// Las instrucciones numeradas de un recorrido que ocurre **fuera** de la app.
///
/// `docs/ux/design-system.md` pedía aquí un `StepChecklist` con estado por paso
/// (pendiente/en curso/hecho/fallido), y eso es justo lo que no se puede construir: iOS no expone qué
/// certificados hay instalados, así que de los pasos 2 y 3 del flujo de la CA no se sabe cuál está
/// hecho — solo se puede preguntar por el resultado final, y eso ya lo dice la etapa. Un checklist con
/// palomitas inventadas sería peor que una lista sin ellas: afirmaría un progreso que nadie ha medido.
/// Así que esto es una lista de instrucciones, y el único estado que hay vive en la etapa.
struct SetupStepList: View {

    let steps: [CertificateSetupStep]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.card) {
            ForEach(steps) { step in
                StepRow(step: step)
            }
        }
    }
}

/// Un paso: su número, qué se hace y dónde.
private struct StepRow: View {

    let step: CertificateSetupStep

    /// El círculo del número crece con el cuerpo de letra: fijo en 24 pt, con los tamaños de
    /// accesibilidad el dígito se saldría de su fondo.
    @ScaledMetric(relativeTo: .footnote) private var badgeDiameter: CGFloat = 24

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // El círculo escala con la letra, así que a AX5 se lleva casi un tercio del ancho y deja la
        // instrucción en una columna estrecha. Apilarlo es lo que hace el resto de la app con sus filas
        // de dos columnas; aquí además el número sigue leyéndose antes que el paso, que es su orden.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.close))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.row))

        return layout {
            // `verbatim` porque un número no es copia: dejarlo como literal interpolado convertía el
            // círculo del paso en una unidad de traducción («%lld») que nadie puede traducir.
            //
            // El círculo es la marca sobre su propio tinte, y su opacidad es un valor **medido**
            // (`FillOpacity.tinted`): por encima de ella el dígito deja de llegar al 7:1 del contraste
            // alto. Por eso mismo esta lista va dentro de una tarjeta y no suelta sobre el lienzo.
            Text(verbatim: "\(step.number)")
                .font(.supporting.monospacedDigit().bold())
                .foregroundStyle(Color(.brand))
                .frame(width: badgeDiameter, height: badgeDiameter)
                .background(Color(.brand).opacity(FillOpacity.tinted), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(step.title)
                    .font(.cardBody.weight(.semibold))

                Text(step.detail)
                    .font(.supporting)
                    .foregroundStyle(Color(.neutral))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        // El número se lee como parte de la frase y no como un elemento suelto: quien escucha necesita
        // saber en qué punto del recorrido va, y los pasos se dan saliendo de la app entre uno y otro.
        // La frase la compone el paso y no esta vista: separador y orden son propiedad de un idioma.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(step.accessibilityLabel)
    }
}
