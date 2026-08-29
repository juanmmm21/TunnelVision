import SwiftUI

/// El hueco de una pantalla cuando no hay lista que enseñar: el vacío que enseña y el error
/// accionable (principio 7 de `docs/ux/00-ux-principles.md`).
///
/// La copia, el símbolo, el papel de color y la acción vienen ya decididos en el `ScreenPlaceholder`
/// que le pasan; esta vista no elige nada, solo lo pinta y avisa de la pulsación. Es genérica sobre
/// la acción para que cada pantalla conserve su conjunto cerrado y no haya una tarjeta por pantalla.
struct PlaceholderCard<Action: Sendable & Equatable>: View {

    let placeholder: ScreenPlaceholder<Action>
    let onAction: (Action) -> Void

    var body: some View {
        VStack(spacing: Spacing.row) {
            Image(systemName: placeholder.systemImage)
                .font(.largeTitle)
                .foregroundStyle(placeholder.role.color)

            Text(placeholder.title)
                .font(.cardTitle)

            Text(placeholder.message)
                .font(.cardBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let diagnostic = placeholder.diagnostic {
                Text(diagnostic)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let title = placeholder.actionTitle, let action = placeholder.action {
                Button(title) { onAction(action) }
                    .brandProminentButton()
                    .padding(.top, Spacing.tight)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.section)
    }
}
