import SwiftUI

/// Un vacío que **enseña** en vez de dejar un hueco (principio 7 de `docs/ux/00-ux-principles.md`).
struct EmptyStateView: View {

    let title: String
    let message: String
    let systemImage: String

    init(title: String, message: String, systemImage: String) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    /// Desde M11 la copia llega ya resuelta desde la capa pura, que es donde se decide **cuál** de los
    /// vacíos de una pantalla toca y donde esa decisión se puede probar.
    init(_ presentation: EmptyStatePresentation) {
        self.init(
            title: presentation.title,
            message: presentation.message,
            systemImage: presentation.systemImage
        )
    }

    var body: some View {
        VStack(spacing: Spacing.close) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(Color(.neutral))
            Text(title)
                .font(.cardTitle)
            Text(message)
                .font(.cardBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.section)
        .accessibilityElement(children: .combine)
    }
}
