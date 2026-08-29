import SwiftUI
import Shared

/// La pantalla de Ajustes (`docs/ux/screens.md`): lo que TunnelVision hace mientras monitoriza, lo
/// que ocupa en el dispositivo y las dos formas de recortarlo.
///
/// La vista no guarda nada, no borra nada y no decide qué se puede encender: pinta lo que le da
/// `SettingsViewModel`, cuya copia sale de funciones puras y probadas. Lo único que resuelve aquí son
/// las dos confirmaciones, porque el gesto es del usuario y las dos consecuencias son irreversibles.
///
/// **No lleva ni una cadena suya**: hasta los rótulos de las secciones, los de los interruptores y los
/// títulos de los dos diálogos salen de `SettingsPresentation`, y *Cancel* y la pista de descartar un
/// aviso de `CommonCopy`. Un literal aquí dentro es una unidad de traducción sin contexto y sin nadie
/// que la afirme (`docs/development/02-coding-standards.md`).
struct SettingsView: View {

    /// El estado del túnel decide si un cambio puede alcanzar a la sesión en curso y si hay un
    /// fichero abierto ahora mismo, así que la pantalla lo sigue igual que Dashboard y Captures.
    let controller: TunnelController

    let viewModel: SettingsViewModel

    /// El intro de la primera ejecución (M10). Esta pantalla es la única forma de volver a verlo, y
    /// es lo que hace que saltarlo no lo pierda para siempre.
    let intro: IntroViewModel

    /// El flujo guiado de la CA (M10). Esta pantalla es su **única** entrada, como pide
    /// `docs/ux/onboarding-and-consent.md`: mirar dentro del tráfico cifrado se decide donde vive el
    /// interruptor que lo gobierna, y no en medio de otra cosa.
    let certificateSetup: CertificateSetupViewModel

    /// El diagnóstico de la sesión. Se abre desde aquí porque la pregunta que contesta —¿está la
    /// inspección haciendo algo?— es la del interruptor que vive dos secciones más arriba.
    let diagnostics: DiagnosticsViewModel

    /// Las dos confirmaciones son estado de la vista y no del view model: nada que confirmar queda
    /// pendiente al salir de la pantalla.
    @State private var isConfirmingApplyCaps = false
    @State private var isConfirmingClearEverything = false
    @State private var isConfirmingClearPlaintext = false

    /// A dónde ha navegado la pantalla. Es una pila explícita y no un `NavigationLink` suelto porque
    /// **volver** es lo que dispara el refresco: el flujo de la CA escribe en el mismo blob de ajustes
    /// que esta pantalla tiene leído, así que hay que saber cuándo se ha vuelto de él.
    @State private var path: [SettingsRoute] = []

    /// Los destinos a los que se llega desde Ajustes. Hoy solo hay uno.
    private enum SettingsRoute: Hashable {
        case certificateSetup
        case diagnostics
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                if let notice = viewModel.notice {
                    Section { noticeBanner(notice) }
                        .listRowBackground(Color(.surface))
                }

                secureTrafficSection
                decryptedContentSection
                captureSection
                storageSection
                introSection
                diagnosticsSection
                aboutSection
            }
            .navigationTitle(SettingsPresentation.screenTitle)
            // El lienzo va en el propio `Form` y no en el `NavigationStack` que lo contiene: un fondo
            // puesto en el contenedor deja la pantalla **sin título grande** (`docs/ux/design-system.md`).
            // Con el fondo del sistema escondido, cada sección pone `surface` en sus filas, así que los
            // dos grises que separan una fila de su fondo son los nuestros y no los de fábrica — la
            // misma decisión que en Captures, que también es una lista agrupada.
            .listCanvas()
            .refreshable { await viewModel.refresh() }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .certificateSetup:
                    CertificateSetupView(viewModel: certificateSetup)
                case .diagnostics:
                    DiagnosticsView(viewModel: diagnostics)
                }
            }
            .confirmationDialog(
                SettingsPresentation.applyCapsDialogTitle,
                isPresented: $isConfirmingApplyCaps,
                titleVisibility: .visible
            ) {
                Button(SettingsPresentation.applyCapsConfirmTitle, role: .destructive) {
                    Task { await viewModel.applyCapsNow() }
                }
                Button(CommonCopy.cancel, role: .cancel) {}
            } message: {
                Text(SettingsPresentation.applyCapsPrompt(viewModel.settings.retention))
            }
            .confirmationDialog(
                SettingsPresentation.clearPlaintextDialogTitle,
                isPresented: $isConfirmingClearPlaintext,
                titleVisibility: .visible
            ) {
                Button(SettingsPresentation.clearPlaintextTitle, role: .destructive) {
                    Task { await viewModel.clearPlaintext() }
                }
                Button(CommonCopy.cancel, role: .cancel) {}
            } message: {
                Text(
                    SettingsPresentation.clearPlaintextPrompt(
                        usage: viewModel.usage,
                        isMonitoring: viewModel.isMonitoring
                    )
                )
            }
            .confirmationDialog(
                SettingsPresentation.clearEverythingDialogTitle,
                isPresented: $isConfirmingClearEverything,
                titleVisibility: .visible
            ) {
                Button(SettingsPresentation.clearEverythingTitle, role: .destructive) {
                    Task { await viewModel.clearEverything() }
                }
                Button(CommonCopy.cancel, role: .cancel) {}
            } message: {
                Text(
                    SettingsPresentation.clearEverythingPrompt(
                        usage: viewModel.usage,
                        isMonitoring: viewModel.isMonitoring
                    )
                )
            }
        }
        .task {
            // Mismo orden que en Captures: seguir el status, leer el real (que corrige el inicial) y
            // solo entonces leer ajustes y disco, para que la retención sepa desde el primer momento
            // si hay un fichero abierto que no se puede tocar.
            controller.startObservingStatus()
            await controller.refresh()
            viewModel.tunnelStateDidChange(to: controller.state)
            diagnostics.tunnelStateDidChange(to: controller.state)
            await viewModel.refresh()
        }
        .onChange(of: controller.state) { _, newState in
            viewModel.tunnelStateDidChange(to: newState)
            diagnostics.tunnelStateDidChange(to: newState)
        }
        // Volver del flujo de la CA relee ajustes y disponibilidad: allí se puede haber creado o
        // borrado el certificado y haberse escrito el interruptor de inspección en el mismo blob que
        // esta pantalla tiene leído, así que quedarse con lo de antes enseñaría un ajuste que ya no es
        // el guardado.
        .onChange(of: path) { _, newPath in
            guard newPath.isEmpty else { return }
            Task { await viewModel.refresh() }
        }
    }

    // MARK: - Secciones

    private var secureTrafficSection: some View {
        Section {
            Toggle(
                SettingsPresentation.tlsInspectionToggleTitle,
                isOn: Binding(
                    get: { viewModel.settings.tlsInspectionEnabled },
                    set: { enabled in Task { await viewModel.setTLSInspection(enabled) } }
                )
            )
            .disabled(!viewModel.isTLSInspectionEditable)

            // La entrada al flujo guiado. Está siempre, también con la inspección ya lista: es donde
            // se rehace el certificado y donde se quita, que es la mitad de la reversibilidad que no
            // cabe en un interruptor.
            NavigationLink(value: SettingsRoute.certificateSetup) {
                Text(SettingsPresentation.certificateSetupTitle(viewModel.tlsAvailability))
            }
        } header: {
            SectionHeader(SettingsPresentation.secureTrafficSectionTitle)
        } footer: {
            footer(SettingsPresentation.tlsFooter(viewModel.tlsAvailability))
        }
        .listRowBackground(Color(.surface))
    }

    /// La sección del ADR 0007: el segundo interruptor, su plazo y su borrado.
    ///
    /// Va **pegada** a la de tráfico seguro y no junto a los topes de la de almacenamiento, aunque
    /// uno de sus controles sea un plazo: la pregunta que contesta es qué pasa con lo que la
    /// inspección descifra, y separarla de la inspección dejaría el segundo interruptor sin la única
    /// cosa que lo hace comprensible — el primero, justo encima.
    private var decryptedContentSection: some View {
        Section {
            Toggle(
                SettingsPresentation.plaintextPersistenceToggleTitle,
                isOn: Binding(
                    get: { viewModel.settings.plaintextPersistenceEnabled },
                    set: { enabled in Task { await viewModel.setPlaintextPersistence(enabled) } }
                )
            )
            .disabled(!viewModel.isPlaintextPersistenceEditable)

            Picker(
                SettingsPresentation.plaintextAgePickerTitle,
                selection: Binding(
                    get: { viewModel.settings.retention.maxPlaintextAge },
                    set: { age in Task { await viewModel.setPlaintextRetentionAge(age) } }
                )
            ) {
                ForEach(PlaintextRetentionAge.allCases, id: \.self) { age in
                    Text(SettingsPresentation.label(for: age)).tag(age)
                }
            }

            Button(role: .destructive) {
                isConfirmingClearPlaintext = true
            } label: {
                if viewModel.activity == .clearing {
                    ProgressView()
                } else {
                    Text(SettingsPresentation.clearPlaintextTitle)
                }
            }
            .disabled(viewModel.activity != .idle || !viewModel.hasPlaintextToClear)
        } header: {
            SectionHeader(SettingsPresentation.decryptedContentSectionTitle)
        } footer: {
            footer(
                SettingsPresentation.plaintextFooter(
                    isInspectionEnabled: viewModel.settings.tlsInspectionEnabled
                ),
                SettingsPresentation.plaintextRetentionFooter
            )
        }
        .listRowBackground(Color(.surface))
    }

    private var captureSection: some View {
        Section {
            Toggle(
                SettingsPresentation.captureToggleTitle,
                isOn: Binding(
                    get: { viewModel.settings.captureEnabled },
                    set: { enabled in Task { await viewModel.setCaptureEnabled(enabled) } }
                )
            )

            Picker(
                SettingsPresentation.captureDetailPickerTitle,
                selection: Binding(
                    get: { viewModel.settings.captureDetail },
                    set: { detail in Task { await viewModel.setCaptureDetail(detail) } }
                )
            ) {
                ForEach(CaptureDetail.allCases, id: \.self) { detail in
                    Text(SettingsPresentation.label(for: detail)).tag(detail)
                }
            }
            .disabled(!viewModel.settings.captureEnabled)
        } header: {
            SectionHeader(SettingsPresentation.captureSectionTitle)
        } footer: {
            footer(
                SettingsPresentation.captureFooter,
                SettingsPresentation.explanation(for: viewModel.settings.captureDetail)
            )
        }
        .listRowBackground(Color(.surface))
    }

    private var storageSection: some View {
        Group {
            Section {
                if let storage = viewModel.storageDisplay {
                    StorageRow(
                        label: SettingsPresentation.storageCapturesRowTitle,
                        figure: storage.captures,
                        isTotal: false
                    )
                    StorageRow(
                        label: SettingsPresentation.storageHistoryRowTitle,
                        figure: storage.history,
                        isTotal: false
                    )
                    // Solo cuando hay: la fila cuenta una función que se enciende dos veces a
                    // propósito, y enseñarla siempre a cero hablaría de algo que puede no haber
                    // existido nunca en este dispositivo.
                    if let plaintext = storage.plaintext {
                        StorageRow(
                            label: SettingsPresentation.storagePlaintextRowTitle,
                            figure: plaintext,
                            isTotal: false
                        )
                    }
                    StorageRow(
                        label: SettingsPresentation.storageTotalRowTitle,
                        figure: storage.total,
                        isTotal: true
                    )
                } else if viewModel.activity == .loading {
                    ProgressView()
                }
            } header: {
                SectionHeader(SettingsPresentation.storageSectionTitle)
            } footer: {
                footer(SettingsPresentation.historyDoesNotShrinkNote)
            }
            .listRowBackground(Color(.surface))

            Section {
                Picker(
                    SettingsPresentation.retentionAgePickerTitle,
                    selection: Binding(
                        get: { viewModel.settings.retention.maxAge },
                        set: { age in Task { await viewModel.setRetentionAge(age) } }
                    )
                ) {
                    ForEach(RetentionAge.allCases, id: \.self) { age in
                        Text(SettingsPresentation.label(for: age)).tag(age)
                    }
                }

                Picker(
                    SettingsPresentation.retentionSizePickerTitle,
                    selection: Binding(
                        get: { viewModel.settings.retention.maxCaptureSize },
                        set: { size in Task { await viewModel.setRetentionSize(size) } }
                    )
                ) {
                    ForEach(RetentionSize.allCases, id: \.self) { size in
                        Text(SettingsPresentation.label(for: size)).tag(size)
                    }
                }
            } header: {
                SectionHeader(SettingsPresentation.limitsSectionTitle)
            } footer: {
                footer(
                    SettingsPresentation.retentionFooter,
                    SettingsPresentation.sizeCapFooter
                )
            }
            .listRowBackground(Color(.surface))

            Section {
                Button {
                    isConfirmingApplyCaps = true
                } label: {
                    if viewModel.activity == .enforcing {
                        ProgressView()
                    } else {
                        Text(SettingsPresentation.applyCapsButtonTitle)
                    }
                }
                .disabled(viewModel.activity != .idle || viewModel.settings.retention.isUnlimited)

                Button(role: .destructive) {
                    isConfirmingClearEverything = true
                } label: {
                    if viewModel.activity == .clearing {
                        ProgressView()
                    } else {
                        Text(SettingsPresentation.clearEverythingTitle)
                    }
                }
                .disabled(viewModel.activity != .idle || !viewModel.hasAnythingToClear)
            }
            .listRowBackground(Color(.surface))
        }
    }

    /// La vuelta al intro. Presentarlo no es cosa de esta pantalla: `RootView` lo tapa todo, así que
    /// aquí solo se pide.
    private var introSection: some View {
        Section {
            Button(SettingsPresentation.introReplayTitle) {
                intro.replay()
            }

            if intro.cannotBeRemembered {
                note(SettingsPresentation.introCannotBeRemembered)
            }
        } header: {
            SectionHeader(SettingsPresentation.introSectionTitle)
        } footer: {
            footer(SettingsPresentation.introFooter)
        }
        .listRowBackground(Color(.surface))
    }

    /// La entrada al diagnóstico. Va al final y en su propia sección, después de todo lo que se
    /// decide: no es un ajuste —no cambia nada— sino la respuesta a "¿está pasando lo que creo?".
    private var diagnosticsSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.diagnostics) {
                Text(DiagnosticsPresentation.entryTitle)
            }
        } footer: {
            footer(SettingsPresentation.diagnosticsFooter)
        }
        .listRowBackground(Color(.surface))
    }

    private var aboutSection: some View {
        Section {
            note(SettingsPresentation.privacyNote)
        } header: {
            SectionHeader(SettingsPresentation.privacySectionTitle)
        }
        .listRowBackground(Color(.surface))
    }

    // MARK: - Los dos textos que no son un control

    /// El pie de una sección: **toda** su prosa, fuera de sus filas y en el orden de las filas de las
    /// que habla.
    ///
    /// Va por aquí y no suelto en cada `footer:` para que el papel tipográfico y el token sean los
    /// mismos en las siete secciones — con el estilo de fábrica los pies eran el gris del sistema, que
    /// no es de nadie, y esta pantalla tiene demasiados como para que se decida uno por uno.
    ///
    /// **Admite varios párrafos porque una regla fija no es una fila.** Tres secciones metían la
    /// explicación de un selector *dentro* de la tarjeta, como una fila más, y en *Decrypted content*
    /// esa fila —92 pt de párrafo— se plantaba entre el selector y el botón de borrar, así que la
    /// tarjeta dejaba de agrupar nada. Y una nota y un pie eran el mismo cuerpo, el mismo peso y el
    /// mismo color: lo único que los distinguía era a qué lado del filo de la tarjeta caían. Aquí
    /// caen del mismo lado, en el orden en que se leen sus filas, y la tarjeta vuelve a ser un grupo
    /// de controles.
    private func footer(_ texts: String...) -> some View {
        VStack(alignment: .leading, spacing: Spacing.close) {
            ForEach(texts, id: \.self) { text in
                Text(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.supporting)
        .foregroundStyle(Color(.neutral))
    }

    /// Lo único que sigue siendo una fila de texto: que la app **no pudo** dejar constancia de que el
    /// intro se vio.
    ///
    /// Es la excepción de la regla de arriba, y la excepción es lo que la define: un pie dice una
    /// regla que vale siempre, y esto es una avería que está pasando ahora — sale solo cuando pasa, y
    /// dentro de la tarjeta está pegada al botón cuyo comportamiento desmiente. Lo mismo que hace que
    /// el estado tenga peso en la Dashboard y que un supuesto calle en la Timeline.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.supporting)
            .foregroundStyle(Color(.neutral))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Aviso

    /// El resultado de la última acción. Se descarta tocándolo, igual que en Captures: es
    /// información, no un diálogo, y dejarlo fijo lo convertiría en ruido.
    private func noticeBanner(_ notice: SettingsNotice) -> some View {
        Button {
            viewModel.dismissNotice()
        } label: {
            HStack(alignment: .top, spacing: Spacing.close) {
                Image(systemName: notice.role == .warning ? "exclamationmark.circle" : "info.circle")
                    .foregroundStyle(notice.role.color)

                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(notice.message)
                        .font(.cardBody)
                        .multilineTextAlignment(.leading)

                    if let diagnostic = notice.diagnostic {
                        Text(diagnostic)
                            .font(.badge)
                            .foregroundStyle(Color(.neutral))
                            .multilineTextAlignment(.leading)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint(CommonCopy.dismissNoticeHint)
    }
}
