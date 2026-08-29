import SwiftUI
import Shared

/// La mitad descifrada del Flow Inspector (`docs/ux/screens.md`, *Flow Inspector*): lo que se dijo por
/// dentro de una conexión inspeccionada, en el orden en que se dijo.
///
/// Es la última pieza de la inspección TLS y donde todo lo anterior se ve: la terminación descifró,
/// el escritor guardó, el índice ató cada trozo a su conexión, el barrido se lleva lo que caduca y
/// `PlaintextLibrary` devuelve los bytes. Aquí se leen.
///
/// Va en pantalla propia y no como una sección más del Flow Inspector porque lo que se contesta de un
/// vistazo es *si* hay algo —eso lo dice la sección que abre esta pantalla— y lo que se dijo es una
/// lista larga que necesita el ancho entero.
struct ConversationView: View {

    /// Se retiene igual que los otros dos: `navigationDestination` reconstruye su contenido en cada
    /// repintado, y sin `@State` cada uno traería un view model nuevo que volvería a leer disco.
    @State private var viewModel: ConversationViewModel

    init(viewModel: ConversationViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        List {
            turns

            if let note = viewModel.chunkLimitNote {
                // Fuera de las tarjetas y al final, que es donde acaba de leer quien llega hasta
                // aquí: no es una cosa dicha por nadie, es lo que falta por enseñar de lo que se
                // dijo. Dentro de una tarjeta más se leería como un turno.
                Text(note)
                    .font(.supporting)
                    .foregroundStyle(Color(.neutral))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        // Lista de tarjetas como la Timeline, no agrupada como las dos fichas de las que se llega: lo
        // que hay aquí son **cosas dichas**, una detrás de otra, y una tarjeta por turno es lo que
        // separa lo que dijo un lado de lo que contestó el otro sin necesidad de una raya.
        .listStyle(.plain)
        .listCanvas()
        .navigationTitle(ConversationPresentation.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await viewModel.load() }
    }

    @ViewBuilder
    private var turns: some View {
        switch viewModel.content {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.row)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

        case .placeholder(let placeholder):
            PlaceholderCard(placeholder: placeholder) { action in
                Task { await viewModel.perform(action) }
            }
            .cardSurface()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

        case .turns(let rows):
            // Ninguna fila lleva a ninguna parte: un turno es el final del camino, no un resumen de
            // algo más. Lo que se puede hacer con él —copiarlo o compartirlo— está dentro de la fila.
            ForEach(rows) { row in
                ConversationTurnCard(row: row)
                    .cardRow()
            }
        }
    }
}
