import Foundation

/// Un hueco de una pantalla con su copia: el vacío que enseña y el error accionable del principio 7
/// de `docs/ux/00-ux-principles.md`.
///
/// Es genérico sobre la acción y no sobre la copia porque lo que cambia entre pantallas es **qué se
/// puede hacer** desde el hueco (la Timeline ofrece limpiar filtros, el Flow Inspector reintentar la
/// carga), no cómo se pinta. Así cada pantalla mantiene su propio conjunto cerrado de acciones —una
/// que no puede ejecutar ni siquiera compila— y todas comparten una sola tarjeta.
public struct ScreenPlaceholder<Action: Sendable & Equatable>: Sendable, Equatable {

    public let title: String
    public let message: String
    public let systemImage: String
    public let role: StatusRole

    public let actionTitle: String?
    public let action: Action?

    /// El detalle técnico del fallo, para enseñarlo en secundario. Igual que en
    /// `MonitoringPresentation`: la copia principal nunca es un mensaje de framework, pero tragárselo
    /// dejaría al usuario sin nada que contar si pide ayuda.
    public let diagnostic: String?

    public init(
        title: String,
        message: String,
        systemImage: String,
        role: StatusRole,
        actionTitle: String? = nil,
        action: Action? = nil,
        diagnostic: String? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.role = role
        self.actionTitle = actionTitle
        self.action = action
        self.diagnostic = diagnostic
    }
}
