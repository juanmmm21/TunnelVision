import SwiftUI
import Shared

/// La pantalla que dice si la inspección está funcionando, y con qué números lo dice.
///
/// Es la única de la app cuyo destinatario es alguien que está **depurando**: hasta ahora estos
/// contadores solo se leían con el depurador enganchado a la extensión, y por eso comprobar en un
/// dispositivo que el sistema deja levantar el listener local que la terminación necesita costaba un
/// Xcode y un cable. Aquí se lee desde el propio teléfono.
///
/// Lo que la hace legible no es la tabla sino el titular: la conclusión la calcula
/// `DiagnosticsPresentation.verdict`, que es puro y está probado. La vista no razona sobre ningún
/// contador — solo los pinta.
struct DiagnosticsView: View {

    let viewModel: DiagnosticsViewModel

    var body: some View {
        List {
            // El DNS va **antes** que el titular de la inspección cuando tiene algo que decir: sin
            // resolución de nombres el dispositivo no navega, y eso explica lo que se está notando
            // mejor que cualquier conclusión sobre una función opcional.
            if let notice = viewModel.resolverNotice {
                Section {
                    banner(notice)
                }
                .listRowBackground(Color(.surface))
            }

            Section {
                headline
            }
            .listRowBackground(Color(.surface))

            // El motivo del fallo **con** contadores en pantalla: sin esto, unos números de hace un
            // rato se leerían como los de ahora mismo.
            if viewModel.stats != nil, let failure = viewModel.failure {
                Section {
                    Label {
                        Text(failure)
                            .font(.supporting)
                            .foregroundStyle(Color(.neutral))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        // El icono lleva el token de aviso y el texto no: el color señala **dónde**
                        // mirar, y pintar de aviso un párrafo entero lo convierte en una alarma.
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color(.warning))
                    }
                }
                .listRowBackground(Color(.surface))
            }

            ForEach(viewModel.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        self.row(row)
                    }
                } header: {
                    SectionHeader(section.title)
                } footer: {
                    // La prosa fija de una sección va debajo de ella y nunca dentro de la tarjeta:
                    // la regla que Ajustes midió, y aquí solo la tiene la que necesita explicar por
                    // qué unas veces enseña una lista y otras tres.
                    if let note = section.note {
                        Text(note)
                            .font(.supporting)
                            .foregroundStyle(Color(.neutral))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .listRowBackground(Color(.surface))
            }

            // Ni contadores ni fallo que contar: el hueco se explica en vez de dejarse en blanco.
            if viewModel.sections.isEmpty, viewModel.failure == nil, viewModel.isMonitoring {
                Section {
                    EmptyStateView(
                        title: DiagnosticsPresentation.emptyTitle,
                        message: DiagnosticsPresentation.emptyDetail,
                        systemImage: "gauge.with.dots.needle.bottom.50percent"
                    )
                }
                .listRowBackground(Color(.surface))
            }
        }
        // Agrupada y sobre nuestro lienzo, igual que Ajustes —de donde se llega— y que Captures: es
        // una tabla de lecturas, no una lista de tarjetas navegables.
        .listStyle(.insetGrouped)
        .listCanvas()
        .navigationTitle(DiagnosticsPresentation.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        // El mismo arreglo que la Timeline, y por el mismo defecto medido aquí: la barra de iOS 26 es
        // cristal, así que los contadores pasaban **por dentro** del título al deslizar — se leía
        // "TCP connections opened · 3.8 MB" atravesando *Session diagnostics*. El color es el lienzo,
        // que es lo que ya hay debajo, así que en lo alto de la lista no aparece ninguna costura.
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(.canvas), for: .navigationBar)
        .refreshable { await viewModel.refresh() }
        .task {
            // Se piden al aparecer y no se sondean: son de baja frecuencia por contrato del canal
            // (`docs/spec/ipc.md`), y quien mira esta pantalla sabe cuándo ha hecho algo que quiere
            // ver reflejado — para eso está el gesto de refrescar.
            await viewModel.refresh()
        }
    }

    /// Una fila de la tabla, en la forma que pide lo que lleva dentro
    /// (`DiagnosticsValueRole`). La vista no decide cuál: solo la dibuja.
    @ViewBuilder
    private func row(_ row: DiagnosticsRow) -> some View {
        switch row.role {
        case .reading:
            ValueRow(label: row.label, value: row.value)
        case .fault:
            faultRow(row)
        case .systemText:
            systemTextRow(row)
        }
    }

    /// Un contador de algo que se perdió, y que no está a cero.
    ///
    /// Es la única fila de la pantalla que se sale del gris, y por eso lleva **símbolo y color** y no
    /// solo color: es la regla de estado de la casa, y aquí además es lo que hace que la marca se
    /// siga con la vista bajando por cuarenta y ocho filas. La fila entera es un elemento para
    /// VoiceOver con la frase que compone el núcleo puro, porque el símbolo no se oye.
    private func faultRow(_ row: DiagnosticsRow) -> some View {
        LabeledContent {
            HStack(spacing: Spacing.close) {
                // El mismo símbolo y el mismo peso que los otros dieciséis avisos de la app: un
                // triángulo relleno aquí sería un peso nuevo inventado para una fila de tabla, y el
                // color ya la separa de las otras cuarenta y siete.
                Image(systemName: "exclamationmark.triangle")
                Text(row.value)
                    .font(.rowValue)
            }
            .foregroundStyle(Color(.warning))
        } label: {
            Text(row.label)
                .font(.cardBody)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(DiagnosticsPresentation.faultDescription(label: row.label, value: row.value))
    }

    /// Lo que contestó el sistema, que no es copia nuestra.
    ///
    /// Va apilado y no en la columna del valor por lo que se midió: un `NSError` entero es un párrafo
    /// de tres líneas, así que en el sitio de una cifra empuja la fila a apilarse de todas formas — y
    /// entonces se lee como la prosa de la app. Sobre la superficie hundida y en el papel de los datos
    /// que se leen carácter a carácter es lo que de verdad es: material citable, como el volcado del
    /// paquete o el diagnóstico del llavero del flujo de la CA.
    private func systemTextRow(_ row: DiagnosticsRow) -> some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            Text(row.label)
                .font(.cardBody)

            Text(row.value)
                .font(.literal)
                .foregroundStyle(Color(.neutral))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sunkenSurface()
        }
    }

    /// El titular: lleva el indicador de la consulta en curso porque es el que se está refrescando.
    private var headline: some View {
        banner(viewModel.headline, isBusy: viewModel.isRefreshing)
    }

    /// Un titular con su icono y su explicación. Es un elemento **único** para VoiceOver: leer el
    /// icono, el titular y el detalle por separado obliga a recomponer la frase a quien la escucha.
    private func banner(_ presentation: DiagnosticsHeadline, isBusy: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            Label {
                Text(presentation.title)
                    .font(.cardTitle)
            } icon: {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: presentation.systemImage)
                        .foregroundStyle(presentation.role.color)
                }
            }

            Text(presentation.detail)
                .font(.cardBody)
                .foregroundStyle(Color(.neutral))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Spacing.tight)
        .accessibilityElement(children: .combine)
    }
}
