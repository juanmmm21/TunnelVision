import SwiftUI

/// Una línea del volcado hexadecimal: posición, bytes y su lectura como texto.
///
/// Monoespaciada en las tres columnas, que es lo único que hace que el volcado se pueda leer: con una
/// fuente proporcional los bytes de una línea no caen debajo de los de la anterior y contar posiciones
/// deja de ser posible. La posición va en secundario porque es referencia, no contenido.
struct HexDumpRow: View {

    let line: HexDumpLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.row) {
            Text(line.offsetLabel)
                .foregroundStyle(Color(.neutral))

            Text(line.hex)

            Text(line.ascii)
                .foregroundStyle(Color(.neutral))
        }
        .font(.dumpLine)
        .accessibilityElement(children: .ignore)
        // VoiceOver lee la posición y el texto, no los 16 pares hexadecimales: leerlos en voz alta uno
        // a uno sería un minuto por línea y no se retiene nada. La frase la compone `HexDumpLine`: el
        // separador y el orden son de un idioma, y aquí no llega ningún traductor.
        .accessibilityLabel(line.accessibilityLabel)
    }
}
