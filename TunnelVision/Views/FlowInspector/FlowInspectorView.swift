import SwiftUI
import Shared

/// El Flow Inspector (`docs/ux/screens.md`): todo sobre una conexión, abierto desde su fila de la
/// Timeline.
///
/// Tres bloques: la 5-tupla en lenguaje humano, la explicación de qué se pudo ver de su contenido
/// —la copia es la misma que la del badge de la fila, que se escribió para encabezar esta pantalla— y
/// la lista de sus paquetes.
///
/// Cada fila de paquete lleva a sus bytes (`PacketDetailView`), que es el salto que
/// `docs/ux/screens.md` pedía y que la localización guardada con cada paquete hizo posible.
struct FlowInspectorView: View {

    /// El view model lo construye la Timeline (es dueña del historial abierto) y aquí se retiene:
    /// `navigationDestination` reconstruye su contenido en cada repintado, y sin `@State` cada uno
    /// traería un view model nuevo que volvería a cargar los paquetes.
    @State private var viewModel: FlowInspectorViewModel

    /// La biblioteca de capturas se pasa **por la vista** y no por el view model, al revés que el
    /// historial: no tiene estado que nadie tenga que poseer —resuelve el directorio en cada llamada,
    /// justo para no cachear un directorio que la extensión ya cambió—, así que hacerla viajar por el
    /// grafo de view models solo añadiría una dependencia que ninguno usa.
    let library: CaptureLibrary

    /// El directorio de contenido descifrado, que viaja por lo mismo y con las mismas reglas que el de
    /// capturas: no tiene estado que nadie tenga que poseer, y quien lo usa es la pantalla que esta
    /// abre.
    let plaintext: PlaintextLibrary

    init(viewModel: FlowInspectorViewModel, library: CaptureLibrary, plaintext: PlaintextLibrary) {
        _viewModel = State(initialValue: viewModel)
        self.library = library
        self.plaintext = plaintext
    }

    var body: some View {
        List {
            Section {
                encryption
                facts
            }
            .listRowBackground(Color(.surface))

            // Va pegada al bloque del cifrado y por encima de los paquetes: lo que se pudo ver del
            // contenido solo se entiende debajo de la explicación de si iba cifrado, y es lo que le da
            // sentido a todo lo de abajo.
            //
            // **Los dos casos pesan distinto y por eso son dos secciones y no una.** Cuando hay
            // conversación, la sección tiene una fila: algo que abrir, en su tarjeta, como cualquier
            // otra cosa que se toca en esta app. Cuando no la hay, lo único que queda es una
            // explicación —y las cuatro explican algo que se arregla en otra pantalla o que no se
            // arregla en ninguna—, así que va de **pie de sección**: conserva cada palabra y pierde la
            // tarjeta, que es lo que la hacía parecer un elemento de una lista de cosas que se tocan.
            if let section = viewModel.contentSection {
                switch section {
                case .conversation(let storedBytes):
                    Section {
                        conversation(storedBytes: storedBytes)
                    } header: {
                        SectionHeader(FlowInspectorPresentation.contentSectionTitle)
                    }
                    .listRowBackground(Color(.surface))

                case .absent(let absence):
                    Section {
                        Text(FlowInspectorPresentation.absenceMessage(absence))
                            .font(.supporting)
                            .foregroundStyle(Color(.neutral))
                            .fixedSize(horizontal: false, vertical: true)
                            // Sin tarjeta y sin separador: es la fila de la sección, así que hereda su
                            // sitio y queda pegada a su encabezado —de pie habría caído a la misma
                            // distancia del encabezado de arriba que del de abajo, sin decir de cuál
                            // de los dos era—, pero no se pinta como algo que se toca.
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } header: {
                        SectionHeader(FlowInspectorPresentation.contentSectionTitle)
                    }
                }
            }

            Section {
                packets
            } header: {
                SectionHeader(FlowInspectorPresentation.packetsSectionTitle)
            } footer: {
                if let note = viewModel.truncationNote {
                    Text(note)
                        .font(.supporting)
                        .foregroundStyle(Color(.neutral))
                }
            }
            .listRowBackground(Color(.surface))
        }
        // Agrupada y no una lista de tarjetas como la Timeline, **a propósito**: la Timeline es un
        // índice del que se sale hacia otro sitio y aquí ya se ha llegado — lo que hay debajo es la
        // ficha de **una** conexión, con sus paquetes como una tabla larga que se recorre de un
        // vistazo. Cientos de tarjetas de dos líneas serían una persiana.
        .listStyle(.insetGrouped)
        .listCanvas()
        .navigationTitle(viewModel.host)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: PacketSummary.self) { packet in
            PacketDetailView(viewModel: PacketDetailViewModel(packet: packet, library: library))
        }
        .navigationDestination(for: ConversationRoute.self) { route in
            ConversationView(
                viewModel: ConversationViewModel(
                    flow: route.flow, chunks: route.chunks, library: plaintext
                )
            )
        }
        // Es el mismo gesto que la Timeline y por el mismo motivo: SQLite no notifica entre procesos y
        // quien escribe es la extensión, así que nada de esto se actualiza si nadie lo pide. Aquí,
        // además, es lo único que mueve la cabecera de una conexión que sigue viva.
        .refreshable { await viewModel.reload() }
        .task { await viewModel.load() }
    }

    // MARK: - Cabecera

    /// Qué se pudo ver del contenido de esta conexión. Encabeza la pantalla porque es lo que decide
    /// qué significa todo lo demás — y en el caso de una app que comprueba su propio certificado, lo
    /// que se lee es una garantía y no una avería (ADR 0003).
    ///
    /// La insignia y su frase son **un solo elemento de accesibilidad**, y eso arregla un defecto que
    /// solo se ve leyendo el árbol: la insignia lleva su propia descripción hablada —etiqueta *más*
    /// explicación, escrita para cuando la frase no está en pantalla— y aquí la frase está justo
    /// debajo, así que VoiceOver la decía **dos veces seguidas**. Ahora la dice el bloque, una vez, con
    /// las mismas palabras.
    private var encryption: some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            TLSStatusBadge(status: viewModel.flow.tlsStatus)
            Text(viewModel.tlsStatus.detail)
                .font(.cardBody)
                .foregroundStyle(Color(.neutral))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Spacing.tight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(viewModel.tlsStatus.accessibilityDescription)
    }

    private var facts: some View {
        FactGrid(facts: viewModel.facts, layout: .pairs)
            .padding(.vertical, Spacing.tight)
    }

    // MARK: - Contenido descifrado

    /// Lo que se dijo, que es lo único de esta sección que se puede abrir.
    ///
    /// **Ninguna ausencia ofrece un botón** (por eso el otro caso no está aquí): las tres que tienen
    /// arreglo se arreglan en Ajustes y con un certificado instalado, y empujar desde aquí a encender
    /// la inspección sería convertir una explicación en un anzuelo.
    private func conversation(storedBytes: UInt64) -> some View {
        NavigationLink(value: viewModel.conversationRoute) {
            Label(
                FlowInspectorPresentation.conversationRowTitle(storedBytes: storedBytes),
                systemImage: "text.alignleft"
            )
        }
    }

    // MARK: - Paquetes

    @ViewBuilder
    private var packets: some View {
        switch viewModel.content {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.row)
                .listRowSeparator(.hidden)

        case .placeholder(let placeholder):
            PlaceholderCard(placeholder: placeholder) { action in
                Task { await viewModel.perform(action) }
            }
            .listRowSeparator(.hidden)

        case .packets(let rows):
            // Todas las filas llevan a su pantalla, también las de un paquete que no se capturó: allí
            // se explica por qué no hay bytes. Una lista donde solo algunas filas responden al toque no
            // deja adivinar cuáles son sin probarlas una a una.
            //
            // Lo que se apila es el **paquete** y no la fila: la copia es un derivado suyo, y meterla
            // en el valor de navegación lo haría cambiar de identidad al cambiar de idioma.
            ForEach(rows) { row in
                NavigationLink(value: row.packet) {
                    PacketRow(row: row)
                }
            }
        }
    }
}
