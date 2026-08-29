import SwiftUI
import Shared

/// La pantalla de **un paquete** (`docs/ux/screens.md`, *Packet detail*): lo que fue, y los bytes que
/// se guardaron de él en el `.pcap`.
///
/// Es el final del salto paquete→bytes: la fila del Flow Inspector trae la `CaptureLocation` guardada
/// con el paquete, `CaptureLibrary` abre ese fichero por su offset y aquí se pinta el registro en
/// hexadecimal y ASCII. Los bytes son el datagrama IP desnudo, tal cual viajó.
struct PacketDetailView: View {

    /// Se retiene igual que el del Flow Inspector: `navigationDestination` reconstruye su contenido en
    /// cada repintado, y sin `@State` cada uno traería un view model nuevo que volvería a leer disco.
    @State private var viewModel: PacketDetailViewModel

    /// Las siglas dejan la línea del titular en los cuerpos de accesibilidad: son dos textos que
    /// crecen a la vez sobre el mismo renglón, y el titular es el que no puede recortarse.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(viewModel: PacketDetailViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        List {
            Section {
                summary
            }
            .listRowBackground(Color(.surface))

            if let headers = viewModel.headers {
                Section {
                    switch headers {
                    case .facts(let decoded, let unread):
                        VStack(alignment: .leading, spacing: Spacing.row) {
                            FactGrid(facts: decoded, layout: .pairs)

                            // Debajo de la rejilla y en el papel de un pie, no dentro de ella: dice
                            // por qué **falta** un dato, así que no es uno más.
                            if let unread {
                                Text(unread)
                                    .font(.supporting)
                                    .foregroundStyle(Color(.neutral))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, Spacing.tight)
                    case .undecodable(let note):
                        Text(note)
                            .font(.cardBody)
                            .foregroundStyle(Color(.neutral))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    SectionHeader(PacketHeaderPresentation.headersSectionTitle)
                }
                .listRowBackground(Color(.surface))
            }

            Section {
                provenance
                bytes
            } header: {
                SectionHeader(PacketBytesPresentation.rawBytesSectionTitle)
            } footer: {
                if let note = viewModel.truncationNote {
                    Text(note)
                        .font(.supporting)
                        .foregroundStyle(Color(.neutral))
                }
            }
            .listRowBackground(Color(.surface))
        }
        // Igual que la pantalla de la que se llega, y por lo mismo: esto es la ficha de **una** cosa,
        // no un índice del que se salga a otro sitio.
        .listStyle(.insetGrouped)
        .listCanvas()
        .navigationTitle(viewModel.packet.event.label)
        .navigationBarTitleDisplayMode(.inline)
        // La regla está escrita desde la Timeline y ya la aplicaba el diagnóstico
        // (`docs/ux/design-system.md`: lo que se desliza bajo la barra necesita que la barra sea
        // opaca), y aquí faltaba: medido a AX5, el encabezado *RAW BYTES* se lee **a través** de
        // *Data* al desplazar, porque la barra de iOS 26 es cristal. El color es el lienzo, o sea el
        // mismo que hay debajo, así que en lo alto de la lista no aparece ninguna costura.
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(.canvas), for: .navigationBar)
        .toolbar {
            // Solo cuando hay volcado: un botón de compartir sobre un hueco compartiría una cadena
            // vacía, y uno deshabilitado permanentemente en las cuatro pantallas sin bytes sería ruido
            // que no lleva a ningún sitio.
            if let dump = viewModel.shareableDump {
                ShareLink(item: dump) {
                    Label(PacketBytesPresentation.shareBytesTitle, systemImage: "square.and.arrow.up")
                }
            }
        }
        .task { await viewModel.load() }
    }

    // MARK: - Cabecera

    /// Lo que el paquete significó y los tres datos que no hace falta abrir ningún fichero para saber.
    ///
    /// De dónde salieron sus bytes ya no se cuenta aquí: eso describe el **registro en disco**, así que
    /// se lee encima de los propios bytes (`provenance`).
    private var summary: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            headline

            Text(viewModel.packet.event.detail)
                .font(.cardBody)
                .foregroundStyle(Color(.neutral))
                .fixedSize(horizontal: false, vertical: true)

            // Tres datos cortos en una fila, y **siempre** tres: es lo que hace que esta rejilla tenga
            // la misma forma en todos los paquetes, lleven siglas o no.
            FactGrid(facts: viewModel.packetFacts, layout: .line)
        }
        .padding(.vertical, Spacing.tight)
    }

    /// El titular y, a su lado, las siglas que el titular **lee**: *Connection opened* es lo que
    /// significa `SYN`, y un dato pegado a su interpretación es una pareja y no dos datos sueltos. Es
    /// donde `PacketRow` ya las pone en la lista de la que se llega, y sacarlas de la rejilla es lo que
    /// deja al resumen con un número fijo de datos.
    private var headline: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.tight))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.row))

        return layout {
            Label(viewModel.packet.event.label, systemImage: viewModel.packet.event.systemImage)
                .font(.cardTitle)
                .foregroundStyle(viewModel.packet.event.role.color)
                // Empuja las siglas al borde derecho sin ser un `Spacer`, que apilado se comería el
                // alto en vez del ancho. Es el mismo apaño que ya usa la fila de la lista.
                .frame(maxWidth: .infinity, alignment: .leading)

            if let flags = viewModel.packet.flagsDetail {
                Text(flags)
                    .font(.metricLabel)
                    .foregroundStyle(Color(.neutral))
                    // En pantalla las siglas se entienden por vecindad; dichas en voz alta y sin nada
                    // delante son una sílaba suelta, así que llevan la frase que las nombra.
                    .accessibilityLabel(PacketBytesPresentation.flagsAccessibilityLabel(flags))
            }
        }
    }

    // MARK: - Bytes

    /// De qué fichero salieron estos bytes y en qué punto de él empiezan, **justo encima de ellos**.
    ///
    /// Estaban en el resumen, entre los datos del paquete, y no hablan del paquete sino del registro
    /// en disco: aquí explican la procedencia de lo que hay debajo, que es lo único a lo que se
    /// refieren. Son dos, así que llenan su fila; el tercero que había —cuánto se guardó— se fue
    /// porque repetía el tamaño del paquete salvo cuando el `snaplen` recortaba, y ese caso lo cuenta
    /// el pie con las dos cifras.
    ///
    /// No hay nada que decir mientras no haya registro leído, y entonces tampoco hay bytes debajo.
    @ViewBuilder
    private var provenance: some View {
        let facts = viewModel.recordFacts
        if !facts.isEmpty {
            FactGrid(facts: facts, layout: .pairs)
                .padding(.vertical, Spacing.tight)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var bytes: some View {
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

        case .bytes(let lines):
            // El volcado se desplaza en horizontal como un bloque: partir una línea de 16 bytes en dos
            // renglones destruiría lo único que lo hace legible, que es que las columnas cuadren.
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    ForEach(lines) { line in
                        HexDumpRow(line: line)
                    }
                }
            }
            // Hundido dentro de la fila, que es para lo que existe esa superficie: los bytes no son
            // una lectura más de la ficha sino **material en bruto** metido dentro de ella, y el
            // escalón es lo que dice dónde empieza y dónde acaba sin gastar una línea en decirlo.
            .sunkenSurface()
            .listRowSeparator(.hidden)
        }
    }
}
