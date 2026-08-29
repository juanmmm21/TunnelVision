import SwiftUI

/// Una fila de tabla: su etiqueta a la izquierda y su valor a la derecha.
///
/// Existe porque las dos pantallas que enseñan cifras en filas —lo que ocupa el disco en Ajustes y
/// los contadores de *Session diagnostics*— las pintaban con `LabeledContent` a secas, y eso deja el
/// valor con el gris del sistema y con la letra del sistema: dos cifras del mismo producto con dos
/// aspectos distintos según la pantalla. Aquí el valor lleva el papel `rowValue` (dígitos de ancho
/// fijo, que es lo que impide que un contador cambie de ancho al refrescarlo) y el token `neutral`.
///
/// No compone texto ni decide nada: recibe la etiqueta y el valor ya formateados por la capa pura.
/// `LabeledContent` se conserva por debajo porque es quien apila etiqueta y valor a los tamaños de
/// accesibilidad — una fila de dos columnas escrita a mano ahí truncaría.
struct ValueRow: View {

    let label: String

    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
                .font(.rowValue)
                .foregroundStyle(Color(.neutral))
        } label: {
            Text(label)
                .font(.cardBody)
        }
    }
}
