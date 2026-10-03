import AppIntents

/// El atajo que la app ofrece sin que nadie lo monte: aparece en Atajos, en Spotlight y en Siri, y
/// se puede asignar al botón de acción.
struct AuditShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlaceAuditMarkerIntent(),
            phrases: [
                "Place an audit marker in \(.applicationName)",
                "Mark \(\.$marker) in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource(
                "audit.shortcut.title",
                defaultValue: "Place Audit Marker",
                comment: "Short name of the app shortcut that places a marker in the open audit session."
            ),
            systemImageName: "flag"
        )
    }
}
