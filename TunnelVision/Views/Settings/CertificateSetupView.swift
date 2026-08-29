import SwiftUI

/// El flujo guiado de la CA (M10, pasos 0–4 de `docs/ux/onboarding-and-consent.md`): la pantalla que
/// lleva al usuario desde "qué es esto y qué cuesta" hasta un certificado que iOS confía, saliendo de
/// la app dos veces por el camino.
///
/// La vista no decide nada. Qué se ve, qué dicen los botones, qué instrucciones se enseñan y qué se
/// puede afirmar sale de `CertificateSetupPresentation` y de `CertificateSetupViewModel`, que ya están
/// probados. Lo que sí es de aquí son dos cosas, y las dos son de presentación:
///
/// 1. **Volver del segundo plano vuelve a preguntar.** Todo lo que este flujo pide se hace *fuera* de
///    la app —en Ficheros y en dos sitios distintos de los Ajustes de iOS—, así que la vuelta es el
///    momento exacto en que la respuesta del sistema puede haber cambiado. Sin esto, el usuario
///    volvería con el certificado ya confiado a una pantalla que le sigue pidiendo instalarlo.
/// 2. **La acción en curso se ve.** Mirar el llavero y evaluar la confianza tardan lo que tardan, y una
///    pantalla muda invita a tocar dos veces lo que solo se puede hacer una (crear la CA, sobre todo).
///
/// Se **empuja** desde Ajustes en vez de presentarse como hoja, y eso no es estética: el recorrido sale
/// de la app varias veces (a Ficheros y a dos sitios distintos de los Ajustes de iOS), y volver a un
/// modal que se puede cerrar de un arrastre sin querer es peor que volver a una pantalla con su botón
/// de atrás y la pestaña donde vive el interruptor todavía a la vista.
struct CertificateSetupView: View {

    let viewModel: CertificateSetupViewModel

    @Environment(\.dismiss) private var dismiss

    /// La vuelta desde los Ajustes de iOS. Es la costura que hace verdad la regla de que la etapa la
    /// dice el sistema y no un contador.
    @Environment(\.scenePhase) private var scenePhase

    /// El icono de la etapa sigue al cuerpo de letra —fijo, en los tamaños de accesibilidad quedaría
    /// diminuto al lado del titular al que acompaña— pero por la **curva más plana**, que es la del
    /// intro y por la misma razón: colgado de `.title2` medía 105 puntos a AX5, más que el titular y
    /// un tercio de la primera pantalla de una etapa cuyo cuerpo son cinco instrucciones. Un adorno
    /// que acompaña a un titular crece con él, no más que él.
    @ScaledMetric(relativeTo: .largeTitle) private var stageIconSize: CGFloat = 44

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// **Dónde vive la barra de botones**, y es la única decisión de layout que esta pantalla toma por
    /// sí misma. Anclada abajo es lo correcto mientras ocupe lo que ocupa una fila de botones; con letra
    /// de accesibilidad son hasta tres botones de dos líneas cada uno, y una barra que no acota su alto
    /// se queda con la mitad de la pantalla — justo en la etapa cuyo cuerpo *es* la lista de pasos que
    /// hay que seguir en otra app. Ni truncaba ni solapaba, así que la regla del sistema de diseño no lo
    /// veía: lo que sobraba no era una fila, era el ancla. Así que a esos tamaños los botones bajan al
    /// final del contenido y la pantalla entera se desplaza como una sola cosa.
    private var scrollsActions: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                header

                if let notice = viewModel.notice {
                    noticeBanner(notice)
                }

                if let note = viewModel.presentation.note, note.placement == .ownSurface {
                    systemNote(note.text)
                }

                guidanceCard

                if viewModel.showsRemovalGuidance {
                    removalGuidance
                }

                manageSection

                // Con letra de accesibilidad los botones bajan aquí, al final de lo que se lee.
                if scrollsActions {
                    actions
                        .padding(.horizontal, -Spacing.card)
                }
            }
            .padding(Spacing.card)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // El lienzo va en el `ScrollView` y no en el contenedor, igual que en las pantallas de lista.
        .screenCanvas()
        .navigationTitle(CertificateSetupPresentation.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.refresh() }
        .safeAreaInset(edge: .bottom) {
            if !scrollsActions { actions }
        }
        .sheet(item: profileHandoff) { handoff in
            CertificateProfileSheet(url: handoff.url) { viewModel.dismissProfile() }
        }
        .confirmationDialog(
            viewModel.confirmation?.title ?? "",
            isPresented: confirmationPrompt,
            titleVisibility: .visible,
            presenting: viewModel.confirmation
        ) { confirmation in
            Button(confirmation.confirmTitle, role: .destructive) {
                // **El valor va con la acción, no se relee del view model.** SwiftUI descarta el
                // diálogo antes de llegar aquí, y ese descarte ya ha vaciado `viewModel.confirmation`:
                // releerlo era el fallo del 2026-08-23 (salía el diálogo, aceptar no hacía nada). Es
                // lo mismo que hace la confirmación de borrado de Captures, que por eso sí funcionaba.
                Task { await viewModel.confirm(confirmation) }
            }
            Button(CommonCopy.cancel, role: .cancel) { viewModel.dismissConfirmation() }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .task { await viewModel.start() }
        .onChange(of: scenePhase) { _, phase in
            // Solo al volver: preguntar al irse no cambiaría nada y correría con el propio cierre.
            guard phase == .active else { return }
            Task { await viewModel.refresh() }
        }
        .onChange(of: viewModel.isFinished) { _, isFinished in
            if isFinished { dismiss() }
        }
    }

    // MARK: - Cabecera

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            // El símbolo se queda **suelto sobre el lienzo**, y no con el disco teñido del intro
            // aunque el papel sea el mismo: `FillOpacity.tinted` está medida contra una superficie de
            // tarjeta y sobre el lienzo no se sostiene con ninguna opacidad en la que aún se vea. Una
            // regla no es su respuesta: aquí la respuesta es no tener disco.
            Image(systemName: viewModel.presentation.systemImage)
                .font(.system(size: stageIconSize))
                .foregroundStyle(viewModel.presentation.role.color)
                .accessibilityHidden(true)

            Text(viewModel.presentation.title)
                .font(.screenHeadline)

            // La prosa y su remate van en un bloque propio, y no sueltos en la cabecera, por el
            // hueco: entre los dos hace falta más aire que entre el titular y la prosa, o la nota se
            // lee como un párrafo más de un cuerpo que ya tiene dos.
            VStack(alignment: .leading, spacing: Spacing.card) {
                Text(viewModel.presentation.message)
                    .font(.prose)
                    .foregroundStyle(Color(.neutral))
                    .fixedSize(horizontal: false, vertical: true)

                // La nota de una etapa **sin recorrido** se lee aquí, en la misma columna que la
                // prosa y sin caja alrededor: es lo que la etapa afirma, y las tres promesas del paso
                // 0 metidas en una tarjeta eran lo más apagado de la pantalla que descansa sobre
                // ellas. Fuera de ella el texto gana el ancho entero (370 puntos contra 346), que es
                // el efecto secundario que ya midió Ajustes.
                if let note = viewModel.presentation.note, note.placement == .belowMessage {
                    Text(note.text)
                        .font(.supporting)
                        .foregroundStyle(Color(.neutral))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// El recorrido por los Ajustes de iOS y, al pie, lo que hay que advertir **de él**.
    ///
    /// Los pasos van **en tarjeta**, y eso no es decoración: el círculo teñido de cada número es la
    /// marca escrita sobre su propio tinte, y eso solo llega al 7:1 que exige el contraste alto encima
    /// de una superficie de tarjeta — sobre el lienzo no lo alcanza con ninguna opacidad usable
    /// (`FillOpacity.tinted`).
    ///
    /// El pie va **dentro** de esa tarjeta y sin filo que lo separe: no son dos superficies, es el
    /// remate de una, y una regla entre ellos sería una tercera cosa que mirar. Lo que los distingue
    /// ya está puesto — el pie no tiene número y arranca en el filo de la tarjeta, no en la columna
    /// del texto de los pasos.
    @ViewBuilder
    private var guidanceCard: some View {
        if !viewModel.presentation.guidance.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.card) {
                SetupStepList(steps: viewModel.presentation.guidance)

                if let note = viewModel.presentation.note, note.placement == .footOfGuidance {
                    Text(note.text)
                        .font(.supporting)
                        .foregroundStyle(Color(.neutral))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }

    /// Lo que contestó el sistema cuando no se dejó mirar el llavero.
    ///
    /// Conserva su propia superficie porque es el único caso que sigue siendo **una avería que ocurre
    /// ahora**, y va en el papel de los datos que se leen carácter a carácter: un
    /// `errSecInteractionNotAllowed` en tipografía proporcional y gris se lee como una frase, y es
    /// justo lo contrario — es un identificador que se copia tal cual para buscarlo.
    private func systemNote(_ diagnostic: String) -> some View {
        Text(diagnostic)
            .font(.literal)
            .foregroundStyle(Color(.neutral))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(padding: Spacing.row, radius: CornerRadius.medium)
    }

    /// Las instrucciones para quitar el perfil. Aparecen **después** de borrar la clave y no antes:
    /// hasta entonces no hay nada que retirar.
    private var removalGuidance: some View {
        VStack(alignment: .leading, spacing: Spacing.row) {
            Text(CertificateSetupPresentation.removalGuidanceTitle)
                .font(.cardTitle)

            SetupStepList(steps: CertificateSetupPresentation.removalSteps)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }

    // MARK: - Las dos acciones destructivas

    /// Rehacer y quitar. Solo aparecen cuando **consta** que hay una CA: ofrecerlas sobre un llavero
    /// que no se dejó mirar convertiría cualquiera de las dos en un borrado a ciegas.
    @ViewBuilder
    private var manageSection: some View {
        if viewModel.canRegenerate || viewModel.canRemove {
            // La línea que separaba esto de lo de arriba se ha ido por lo mismo que en la Timeline:
            // dos superficies se separan solas, y una regla entre ellas es una tercera cosa que
            // mirar.
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: 0) {
                    if viewModel.canRegenerate {
                        Button {
                            viewModel.requestRegenerate()
                        } label: {
                            manageLabel(CertificateSetupPresentation.regenerateActionTitle)
                        }
                        .disabled(viewModel.activity != .idle)
                    }

                    if viewModel.canRemove {
                        Button(role: .destructive) {
                            viewModel.requestRemove()
                        } label: {
                            manageLabel(CertificateSetupPresentation.removeActionTitle)
                        }
                        .disabled(viewModel.activity != .idle)
                    }
                }
                // El relleno va **solo a los lados**: dos filas de 44 puntos ya traen su propio aire
                // arriba y abajo, y sumarle el de la tarjeta dejaba el primer rótulo a 24 puntos del
                // filo. Lo horizontal sí, para que los dos rótulos arranquen en la misma columna que
                // el texto de las demás tarjetas de la pantalla.
                .padding(.horizontal, Spacing.card)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardSurface(padding: 0)

                // La explicación de las dos acciones va **debajo** de su tarjeta, no dentro: es prosa
                // fija de la sección, y dentro se leía como una tercera fila entre dos botones. Es la
                // misma regla que Ajustes aplicó a sus tres selectores, con el mismo efecto medible —
                // fuera de la caja el texto tiene el ancho entero y ocupa menos.
                Text(CertificateSetupPresentation.manageFooter)
                    .font(.supporting)
                    .foregroundStyle(Color(.neutral))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// El rótulo de una de las dos acciones de gestión.
    ///
    /// Ocupan la **fila entera** de su tarjeta y no lo que mida su texto, que es lo que las convertía
    /// en dos objetivos de 172 × 19 y 256 × 19 puntos — el segundo de ellos destructivo. Sexta vez que
    /// sale la misma trampa: el marco va en el rótulo, porque en un botón sin relleno propio lo que
    /// recibe el toque es el texto. Y con 44 puntos de alto cada una dejan de necesitar separación:
    /// era `Spacing.close` lo único que distinguía dos acciones seguidas de dos líneas de un párrafo.
    private func manageLabel(_ title: String) -> some View {
        Text(title)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.minimum, alignment: .leading)
            .contentShape(Rectangle())
    }

    // MARK: - Botones

    /// Los botones de la etapa. La salida está en todas menos en la que **es** salir, y mientras algo
    /// está en marcha no se puede tocar ninguno: crear la CA dos veces reemplazaría la que acaba de
    /// crearse.
    private var actions: some View {
        VStack(spacing: Spacing.row) {
            Button {
                perform(viewModel.presentation.primary.action)
            } label: {
                Group {
                    if viewModel.activity == .idle {
                        Text(viewModel.presentation.primary.title)
                    } else {
                        ProgressView()
                    }
                }
                // Sin `minHeight`: `.controlSize(.large)` ya entrega 49,3 puntos de alto por su
                // propio relleno, y sumarle el mínimo encima lo subía a 74 — el mínimo se aplica
                // donde falta, no en todos los botones de la pantalla.
                .frame(maxWidth: .infinity)
            }
            // `.brandProminentButton()` y no `.borderedProminent` a secas: el relleno por defecto es
            // el acento global, que es la marca **como tinta** y en oscuro tiene que ser clara — con
            // él, el botón principal de este flujo era rótulo blanco sobre cian claro.
            .brandProminentButton()
            .controlSize(.large)
            .disabled(viewModel.activity != .idle)

            if let secondary = viewModel.presentation.secondary {
                Button {
                    perform(secondary.action)
                } label: {
                    // El ancho va en el **rótulo**, que es lo que lo separa del `.frame` que había
                    // aquí puesto sobre el botón: el relleno de `.bordered` se ciñe a su etiqueta, así
                    // que la pastilla medía 143,7 puntos contra los 370,3 del botón de arriba y solo
                    // esos 143,7 recibían el toque. Y no es el botón de segunda de la pantalla: en la
                    // etapa de instalación es el que **avanza la etapa** cuando el usuario vuelve de
                    // los Ajustes de iOS. Alto no lleva por lo mismo que el de arriba: `.large` ya lo
                    // pone.
                    Text(secondary.title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(viewModel.activity != .idle)
            }

            if let exit = viewModel.presentation.dismiss {
                Button {
                    perform(exit.action)
                } label: {
                    // La salida **no** es el botón de segunda: la regla de consentimiento de la spec
                    // dice que nunca hay un solo botón, así que es el que hace legal al de arriba — y
                    // entregaba 60 × 19 puntos en el paso 0 y 79 × 19 en la etapa de instalación. Va
                    // con su objetivo mínimo y sin ancho completo, como el `Skip` del intro: las dos
                    // que ocupan la columna entera son las que hacen algo.
                    Text(exit.title)
                        .frame(minWidth: TouchTarget.minimum, minHeight: TouchTarget.minimum)
                }
                .disabled(viewModel.activity != .idle)
            }
        }
        .padding(.horizontal, Spacing.card)
        .padding(.vertical, Spacing.row)
        // El lienzo también en la banda fija, igual que en la Timeline. Y aquí sí lleva filo arriba:
        // la banda y lo que se desplaza por debajo son el **mismo** color, así que sin la línea no se
        // sabría dónde acaba el contenido — es lo contrario del caso de dos superficies distintas.
        .background(Color(.canvas))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.surfaceStroke))
                .frame(height: StrokeWidth.hairline)
        }
    }

    private func perform(_ action: CertificateSetupAction) {
        Task { await viewModel.perform(action) }
    }

    // MARK: - Avisos

    /// Cómo terminó la última acción. Se descarta tocándolo, igual que en Ajustes y en Captures: es
    /// información sobre lo que acaba de pasar, no un diálogo.
    private func noticeBanner(_ notice: CertificateSetupNotice) -> some View {
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
            .cardSurface(padding: Spacing.row, radius: CornerRadius.medium)
        }
        .buttonStyle(.plain)
        .accessibilityHint(CommonCopy.dismissNoticeHint)
    }

    // MARK: - Presentaciones

    /// El perfil escrito y esperando a la hoja del sistema. Se identifica por su URL para que volver a
    /// pedirlo vuelva a presentar la hoja aunque el fichero sea el mismo — soltarlo es lo que
    /// `dismissProfile()` existe para hacer.
    private struct ProfileHandoff: Identifiable {
        let id: URL
        var url: URL { id }
    }

    private var profileHandoff: Binding<ProfileHandoff?> {
        Binding(
            get: { viewModel.profileURL.map(ProfileHandoff.init(id:)) },
            set: { handoff in if handoff == nil { viewModel.dismissProfile() } }
        )
    }

    private var confirmationPrompt: Binding<Bool> {
        Binding(
            get: { viewModel.confirmation != nil },
            set: { isPresented in if !isPresented { viewModel.dismissConfirmation() } }
        )
    }
}
