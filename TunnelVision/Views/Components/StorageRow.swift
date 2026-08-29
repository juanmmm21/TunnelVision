import SwiftUI

/// Una fila de la tabla de almacenamiento de Ajustes: qué es, de cuántas cosas se compone y cuánto
/// ocupa.
///
/// **No es un `ValueRow` con dos valores.** Un `ValueRow` es un rótulo y un dato, y aquí hay dos
/// datos que no se leen por lo mismo: el tamaño se lee **comparando** —cuál de las tres se está
/// comiendo el disco— y la cuenta **sitúa** ese tamaño. Escritos con el mismo papel y el mismo color,
/// como estaban (`3 files · 6.6 MB` en una sola cadena), la única cifra por la que se lee la sección
/// compartía renglón con una que no se compara con ninguna otra, y las cuatro filas se leían como
/// prosa. Es el mismo defecto que Captures se quitó el 2026-08-20, y el código que lo escribía citaba
/// aquella fila como su razón para escribirlo.
///
/// El `·` que las unía se fue con ellas: lo que separa las dos cifras es el papel y el color, y un
/// separador compuesto en la vista sería copia en el único sitio al que un traductor no llega (la
/// misma decisión que en `CaptureFileRow` y en `FlowRow`).
struct StorageRow: View {

    let label: String

    let figure: StorageFigure

    /// Si esta fila es la **suma** de las de arriba.
    ///
    /// **Sin valor por defecto**, como `MonitoringProminence` o `FactGridLayout`: una fila nueva en
    /// esta tabla tiene que decir si es una parte o el todo, y no heredarlo. Es lo único de la
    /// sección que carga con énfasis, porque es la cifra que contesta la pregunta por la que se abre
    /// —cuánto está ocupando la app— y las otras tres son su desglose. Sin él las cuatro pesaban lo
    /// mismo y el ojo no tenía dónde caer.
    let isTotal: Bool

    /// A tamaños de accesibilidad las tres columnas dejan de caber, y el reparto que sale es peor que
    /// apilarlas: *255 connections* se partía en tres renglones mientras *619 KB* se quedaba arriba a
    /// la derecha, así que dos filas con el mismo contenido salían con formas distintas según lo que
    /// midiera su cuenta. La decide el **umbral de tamaño de letra** y no un `ViewThatFits`, por lo
    /// mismo que en `FlowRow` y en `CaptureFileRow`: una fila se lee contra las demás, así que todas
    /// tienen que cambiar a la vez.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        content
            // Un solo elemento: el árbol se recorre por posición, así que rótulo, cuenta y tamaño
            // sueltos se oirían como tres cosas seguidas sin decir que la segunda y la tercera
            // hablan de la primera. La frase se compone en el núcleo puro.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(
                SettingsPresentation.storageRowAccessibilityValue(figure)
            )
    }

    @ViewBuilder
    private var content: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                title
                count
                size
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.close) {
                title
                    // Hace el trabajo del `Spacer` que separaría el rótulo de las cifras, que apilado
                    // se comería el alto en vez del ancho.
                    .frame(maxWidth: .infinity, alignment: .leading)

                count
                size
            }
        }
    }

    private var title: some View {
        Text(label)
            .font(isTotal ? .cardTitle : .cardBody)
    }

    /// La cuenta, en voz baja. Es contexto del tamaño y no un dato que se compare con el de la fila
    /// de al lado, así que va con el papel de rótulo de métrica y el token apagado — lo mismo que la
    /// hora de un fichero en Captures, por la misma razón.
    @ViewBuilder
    private var count: some View {
        if let count = figure.count {
            Text(count)
                .font(.metricLabel)
                .foregroundStyle(Color(.neutral))
        }
    }

    /// Lo que ocupa, al final de la línea y con los dígitos de ancho fijo de `rowValue`: lo que tiene
    /// que caer en la misma vertical es el **borde derecho**, porque una cantidad se compara por su
    /// final y no por su principio (`6.6 MB` contra `619 KB`).
    ///
    /// El total es el único que va con la tinta de primer plano. Que sea el único sitio oscuro de la
    /// sección es la jerarquía: se lee primero la suma y después de qué se compone.
    private var size: some View {
        Text(figure.size)
            .font(.rowValue)
            .foregroundStyle(isTotal ? AnyShapeStyle(.foreground) : AnyShapeStyle(Color(.neutral)))
            .multilineTextAlignment(.trailing)
    }
}
