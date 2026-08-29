import Foundation

/// Los papeles de color del sistema de diseño (`docs/ux/design-system.md`), como **valor puro**.
///
/// Vive aquí y no en la vista para que la decisión "qué papel le toca a este estado" se pueda probar
/// sin pintar nada; el mapeo papel → `Color` es lo único que sabe SwiftUI (`Views/Palette.swift`).
///
/// Los cuatro papeles de estado TLS son los de la tabla de la spec y **no** se colapsan en los tres
/// genéricos: el badge de una conexión tiene que distinguirse de un aviso de la app aunque hoy
/// compartan color, porque lo que significan es distinto y el catálogo de M11 los separará.
public enum StatusRole: Sendable, Equatable {
    /// Acción principal y monitorización activa.
    case accent
    /// Estado en reposo, sin alarma.
    case neutral
    /// Algo que el usuario debería mirar (back-pressure, permiso denegado).
    case warning
    /// Conexión sin cifrar.
    case plaintext
    /// Conexión cifrada que no se ha mirado.
    case encrypted
    /// Conexión descifrada con el consentimiento del usuario.
    case inspected
    /// Conexión que rechazó la CA local y se relayeó intacta (ADR 0003).
    case notInspectable
}
