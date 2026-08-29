import SwiftUI

/// El único sitio donde un papel del sistema de diseño se convierte en un color.
///
/// Desde el sistema visual (paso 8 del roadmap) los colores salen del **catálogo**
/// (`Resources/Assets.xcassets`), que es lo que `docs/ux/design-system.md` pedía desde el principio:
/// cada papel tiene su color con variantes de claro, oscuro y contraste alto, y ninguna vista escribe
/// un color a mano. Antes se mapeaban a los colores semánticos del sistema, que se adaptaban solos
/// pero no eran de nadie: la app se veía como el ajuste de fábrica de SwiftUI.
///
/// El mapeo papel → token es puro y está probado (`Models/DesignTokens.swift`); aquí solo se resuelve
/// el token contra el catálogo.
extension StatusRole {
    var color: Color { Color(colorToken) }
}

/// Los dos sentidos del tráfico, con color y símbolo fijos en toda la app: el gráfico, las fichas y
/// las filas de hosts tienen que usar el mismo, o el usuario no puede leerlos juntos. Las etiquetas
/// vienen de `DirectionLabel`, que es la mitad pura y probada de lo mismo.
enum TrafficDirectionStyle {
    static let inboundColor = Color(.trafficInbound)
    static let outboundColor = Color(.trafficOutbound)
    static let inboundSymbol = "arrow.down"
    static let outboundSymbol = "arrow.up"
    static let inboundLabel = DirectionLabel.inbound
    static let outboundLabel = DirectionLabel.outbound
}
