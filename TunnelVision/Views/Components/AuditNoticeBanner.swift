import SwiftUI

/// El aviso de la última acción de auditoría que no salió. Se descarta tocándolo, igual que en
/// Captures y en Ajustes: es información, no un diálogo.
///
/// Es una vista y no una función privada de pantalla porque aquí lo enseñan tres —la lista de
/// proyectos, un proyecto y una sesión—, que comparten view model y por tanto el mismo aviso.
struct AuditNoticeBanner: View {

    let notice: AuditNotice
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
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

/// El distintivo de lo que está grabando ahora, con icono **y** etiqueta **y** color
/// (`docs/ux/design-system.md`). El mismo en la lista de proyectos y en la de sesiones.
struct AuditRecordingBadge: View {

    var body: some View {
        // Un `HStack` y no un `Label`: dentro de una `List`, el icono de un `Label` se va a la
        // columna de iconos de la fila y deja la palabra a 28 pt de su símbolo.
        HStack(spacing: Spacing.tight) {
            Image(systemName: "record.circle")
                .accessibilityHidden(true)
            Text(AuditPresentation.recordingBadge)
        }
        .font(.badge)
        .foregroundStyle(StatusRole.accent.color)
    }
}

/// Lo que un formulario de auditoría tiene mal, junto al campo que lo tiene: símbolo **y** frase
/// **y** color.
///
/// Un `HStack` y no un `Label` por lo mismo que el distintivo de arriba: en una fila de lista el
/// icono de un `Label` se va a la columna de iconos y la frase queda sangrada bajo un campo que no
/// lo está.
struct AuditFormIssueText: View {

    let issue: AuditFormIssue

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
            Image(systemName: "exclamationmark.circle")
                .accessibilityHidden(true)
            Text(AuditPresentation.message(for: issue))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.supporting)
        .foregroundStyle(StatusRole.warning.color)
    }
}

/// El pie de una sección de las pantallas de auditoría: la prosa fija va **bajo** la sección y nunca
/// dentro de la tarjeta, con el papel y el color que usa Ajustes para lo mismo.
struct AuditSectionFooter: View {

    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.supporting)
            .foregroundStyle(Color(.neutral))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
