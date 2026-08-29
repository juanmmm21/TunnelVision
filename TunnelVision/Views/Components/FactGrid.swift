import SwiftUI

/// Los datos duros de algo, en rejilla: cada uno su rótulo y, **justo debajo**, su valor.
///
/// La usan las dos pantallas que describen una cosa concreta —una conexión en el Flow Inspector y un
/// paquete en la suya—, y existe como componente porque las dos la tenían escrita **entera y por
/// separado**, incluida la regla de cuántas columnas caben. Dos copias de una rejilla es como dos
/// pantallas del mismo producto acaban con los mismos datos puestos de dos maneras.
///
/// **Cada celda llevaba un icono delante del rótulo y ya no.** Era un pictograma inventado para
/// acompañar a una palabra que ya estaba escrita al lado (una regla junto a *Size*, un reloj junto a
/// *Duration*), o sea la misma clase de adorno que se fue de las filas de la Timeline; y aquí tenía
/// además un coste que se ve sin medirlo: el icono ocupaba la sangría del rótulo mientras el valor
/// empezaba en el borde de la celda, así que **ningún valor caía debajo del suyo** y de una rejilla
/// de dos columnas solo estaban alineados los dos bordes izquierdos. Sin él, rótulo y valor comparten
/// un borde y la celda es por fin una columna. El porqué del dato, cuando hace falta, lo lleva el
/// rótulo —que es donde se puede traducir—, no un símbolo.
enum FactGridLayout: Equatable {

    /// Dos columnas leídas por filas. Es la forma de una **tabla** de datos, y su consecuencia es que
    /// cada dato tiene un vecino: quien la elige ordena los suyos en parejas.
    case pairs

    /// Una sola fila, con una columna por dato. Es la forma de un grupo **pequeño y de tamaño fijo**
    /// cuyos valores son cortos — donde dos columnas dejarían media rejilla vacía o, peor, una fila
    /// suelta al final.
    case line
}

struct FactGrid: View {

    let facts: [FlowFact]

    /// Cómo se reparten. **No tiene valor por defecto**: un grupo nuevo de datos tiene que elegir su
    /// forma en vez de heredarla, que es lo mismo que ya hacen el peso del control de monitorización
    /// y el énfasis de un estado de cifrado.
    let layout: FactGridLayout

    /// La rejilla pierde su segunda columna en los cuerpos de accesibilidad: a media pantalla los
    /// rótulos se silabean (*Ser-/vice*, *Star/ted*) y los valores se parten en dos líneas. Es el mismo
    /// criterio con el que las filas de la app se apilan — aquí no hay `HStack` que cambiar, sino una
    /// columna que quitar.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Spacing.row) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(fact.label)
                        .font(.metricLabel)
                        .foregroundStyle(Color(.neutral))

                    // El mismo papel que el valor de una fila de tabla, y por lo mismo: son cifras que
                    // se releen al refrescar una conexión viva, y sin dígitos de ancho fijo el dato
                    // cambia de sitio a cada lectura.
                    value(of: fact)
                        .font(.rowValue)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var columns: [GridItem] {
        let column = GridItem(.flexible(), alignment: .topLeading)
        guard !dynamicTypeSize.isAccessibilitySize else { return [column] }

        switch layout {
        case .pairs:
            return [column, column]
        case .line:
            // Tantas columnas como datos, que es lo que la hace **una fila**: el caller elige esta
            // forma sabiendo cuántos son y cuánto miden, igual que elegiría un ancho.
            return Array(repeating: column, count: max(1, facts.count))
        }
    }

    /// Los números vienen ya formateados y son deterministas; una hora **sí** se localiza (12/24 h es
    /// del dispositivo), así que esa la formatea aquí SwiftUI. Y un tramo entre dos horas lo formatea
    /// el **estilo de intervalo** del sistema y no dos horas con un guion en medio: dónde va el
    /// separador, y si las dos mitades repiten o no la parte que comparten, es propiedad de un idioma.
    @ViewBuilder
    private func value(of fact: FlowFact) -> some View {
        switch fact.value {
        case .text(let text):
            Text(text)
        case .moment(let date):
            Text(date, format: .dateTime.hour().minute().second())
        case .span(let range):
            Text(range.formatted(.interval.hour().minute().second()))
        }
    }
}
