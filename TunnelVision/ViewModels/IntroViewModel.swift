import Foundation
import Observation
import Shared

/// El view model del intro de la primera ejecución (M10, `docs/ux/onboarding-and-consent.md`).
///
/// Es el más pequeño de la app y aun así tiene tres decisiones que no son de dibujo:
///
/// 1. **Saltar cuenta como visto, porque el intro se puede volver a pedir.** Lo contrario —que saltar
///    no marque nada— convertiría el intro en algo que reaparece en cada arranque hasta que se aguante
///    entero, que es la definición de insistir. Lo que hace que saltar sea seguro es la otra mitad:
///    Ajustes ofrece *Show the introduction again*, así que nada se pierde por un toque. Sin esa
///    salida, marcar visto al saltar sí sería el callejón que prohíbe `docs/ux/00-ux-principles.md`.
/// 2. **Si el almacén no se deja leer, se enseña el intro.** No hay forma de distinguir "instalación
///    nueva" de "no sé dónde mirar", y de las dos salidas posibles solo una es proporcionada: enseñar
///    tres tarjetas a quien ya las vio es una molestia, no explicar nunca la VPN a quien no las ha
///    visto es dejarle sin lo único que le prepara para el diálogo del sistema.
/// 3. **No poder recordarlo no bloquea, pero tampoco se traga.** Un intro que se niega a seguir porque
///    no pudo escribir una preferencia sería desproporcionado —la extensión ya cae a los ajustes de
///    fábrica y arranca igual—, así que el hecho se guarda en `cannotBeRemembered` y lo cuenta la
///    pantalla de Ajustes, que es donde hay a quién contárselo y donde está el botón de repetirlo.
///
/// Es `@MainActor` y `@Observable` como los demás view models. No hay actor por debajo: `SettingsStore`
/// es un `struct` sin estado cuyas dos operaciones son síncronas.
@MainActor
@Observable
public final class IntroViewModel {

    // MARK: - Lo que pinta la vista

    /// Si el intro está delante del usuario.
    public private(set) var isPresented = false

    /// La tarjeta que se está viendo.
    public private(set) var card: IntroCard = .whatItDoes

    /// Cómo terminó el último intro, hasta que quien lo atiende lo consume.
    ///
    /// Se publica en vez de entregarse por una closure porque quien lo atiende es la raíz de la app
    /// (cambia de pestaña y le pide a la Dashboard que encienda) y no este objeto: dárselo por closure
    /// obligaría a construir el view model **después** de la Dashboard, y el intro se decide antes de
    /// que haya pantallas.
    public private(set) var outcome: IntroOutcome?

    /// Que no se haya podido dejar constancia de que el intro se vio, por cualquiera de las dos vías:
    /// el almacén no se dejó leer o no se dejó escribir. La consecuencia es la misma y es visible sola
    /// —el intro volverá a aparecer—, así que lo que aporta el aviso es explicarla antes de que pase.
    public private(set) var cannotBeRemembered = false

    // MARK: - Dependencias

    private let store: SettingsStore

    public init(store: SettingsStore) {
        self.store = store
    }

    // MARK: - Derivados

    public var presentation: IntroPresentation { IntroPresentation.forCard(card) }

    // MARK: - La puerta del arranque

    /// Decide si el intro tiene que aparecer. La llama la raíz de la app al montarse.
    ///
    /// Es idempotente y **no reabre** un intro ya terminado en esta misma ejecución: la raíz se puede
    /// volver a montar, y volver a preguntarle al almacén justo después de haberlo escrito daría la
    /// respuesta correcta, pero justo después de no haberlo **podido** escribir devolvería el intro a
    /// la cara del usuario que acaba de cerrarlo.
    public func prepare() {
        guard outcome == nil, !isPresented else { return }
        do {
            let settings = try store.load()
            isPresented = !settings.hasSeenIntro
        } catch {
            isPresented = true
            cannotBeRemembered = true
        }
    }

    // MARK: - Navegación

    /// El botón primario de la tarjeta que se está viendo.
    public func performPrimaryAction() {
        switch presentation.action {
        case .next:
            // `card(after:)` es quien sabe que de la última no se avanza; aquí un `nil` solo puede
            // significar que la tarjeta ya era la última, y entonces no hay nada que hacer.
            guard let next = IntroPresentation.card(after: card) else { return }
            card = next
        case .startMonitoring:
            finish(.startMonitoring)
        }
    }

    /// La salida de la tarjeta: saltar el resto, o no encender todavía en la última. Las dos terminan
    /// el intro sin pedir nada, que es lo que las hace una salida de verdad y no un rodeo.
    public func skip() {
        guard isPresented else { return }
        finish(.dismissed)
    }

    /// El deslizamiento entre tarjetas. Se acepta cualquiera de la serie porque el gesto no puede
    /// llevar a ninguna otra parte.
    public func show(_ card: IntroCard) {
        self.card = card
    }

    /// Volver a enseñar el intro, desde Ajustes.
    ///
    /// **No borra** que ya se vio: si la app muere a mitad de una relectura voluntaria, el intro no
    /// tiene por qué volver en el arranque siguiente — el usuario ya sabe dónde encontrarlo.
    public func replay() {
        card = .whatItDoes
        outcome = nil
        isPresented = true
    }

    /// La consume quien la atiende. Sin esto, un repintado de la raíz volvería a atender el mismo
    /// desenlace y le pediría a la Dashboard un arranque que el usuario pidió una sola vez.
    public func acknowledgeOutcome() {
        outcome = nil
    }

    // MARK: - Interno

    private func finish(_ outcome: IntroOutcome) {
        markSeen()
        isPresented = false
        self.outcome = outcome
    }

    /// Deja constancia de que el intro se vio.
    ///
    /// Lee, cambia un campo y guarda el `AppSettings` entero, igual que la pantalla de Ajustes: el
    /// almacén guarda un solo blob, así que escribir es siempre escribirlo todo. Sobre un blob
    /// **ilegible** se escribe encima con los ajustes de fábrica, que es lo que ya hace la primera
    /// escritura de la pantalla de Ajustes: lo que había no se podía leer, así que no hay nada que
    /// conservar, y dejarlo sin reparar condenaría al intro a volver en cada arranque.
    private func markSeen() {
        do {
            var settings: AppSettings
            do {
                settings = try store.load()
            } catch SettingsStoreError.corruptData {
                settings = .default
            }
            guard !settings.hasSeenIntro else {
                cannotBeRemembered = false
                return
            }
            settings.hasSeenIntro = true
            try store.save(settings)
            cannotBeRemembered = false
        } catch {
            cannotBeRemembered = true
        }
    }
}
