import SwiftUI

/// La entrega del perfil, **antes** de que aparezca la hoja del sistema (M10, paso 2 de
/// `docs/ux/onboarding-and-consent.md`).
///
/// Existe por la misma regla que `ConsentSheet` y que la hoja del export de conexiones: lo que saca
/// algo del dispositivo se explica antes y nunca después. Y aquí hay algo más que explicar que en el
/// export, porque la hoja del sistema no distingue entre guardar en Ficheros —que es lo que se pide— y
/// mandárselo a otro dispositivo, que es lo único que no se debe hacer con este fichero.
///
/// No decide nada: la copia es `CertificateSetupPresentation.profileHandoff` y el nombre del fichero
/// sale de la URL que el flujo acaba de escribir, no de una constante repetida aquí.
struct CertificateProfileSheet: View {

    let url: URL

    /// Cerrar sin entregar nada. El fichero se queda en el temporal hasta que la CA cambie: quitarlo
    /// aquí correría con la hoja del sistema, que puede estar leyéndolo todavía.
    let onDismiss: () -> Void

    private var handoff: CertificateSetupHandoff { CertificateSetupPresentation.profileHandoff }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.card) {
                    Text(handoff.message)
                        .font(.prose)
                        .fixedSize(horizontal: false, vertical: true)

                    Label(handoff.warning, systemImage: "exclamationmark.shield")
                        .font(.supporting)
                        .foregroundStyle(StatusRole.warning.color)
                        .fixedSize(horizontal: false, vertical: true)

                    // El nombre del fichero es lo que el usuario va a buscar en Ficheros, así que va
                    // monoespaciado (se lee carácter a carácter) y con el token neutral y no con un
                    // gris terciario del sistema, que en claro se quedaba al borde de lo legible.
                    Text(url.lastPathComponent)
                        .font(.literal)
                        .foregroundStyle(Color(.neutral))

                    ShareLink(item: url) {
                        Label(handoff.shareTitle, systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .brandProminentButton()
                    .controlSize(.large)
                }
                .padding(Spacing.card)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .screenCanvas()
            .navigationTitle(handoff.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(CommonCopy.done) { onDismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
