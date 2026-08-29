import Foundation
import Shared

/// Cáscara device-only del stack TLS userspace, abstraída para que la orquestación del interceptor sea
/// testeable en Simulator (igual que `RelayConnection` abstrae `NWConnection`).
///
/// **Es una fábrica, no una operación.** El boceto original (`terminate(flow:sni:) async ->
/// TLSTerminationOutcome`) asumía que el motor podía hacerse con los bytes del flujo por su cuenta, y
/// no puede: el stream reensamblado lo tiene el relay, que es quien lleva la máquina de estados TCP
/// hacia el dispositivo. Así que el motor **construye** la terminación —empareja la sesión de servidor
/// que presenta el leaf del host con la pata saliente al servidor real— y la devuelve con forma de
/// `RelayConnection`, que es la que el relay ya sabe alimentar; el desenlace, que llega cuando el flujo
/// acaba y no cuando se abre, sale por `onOutcome`.
///
/// La conformidad de producción es `NetworkTLSTerminationEngine`. En tests se sustituye por un doble
/// que devuelve una terminación guionizada.
public protocol TLSTerminationEngine: Sendable {
    /// Crea (sin arrancar) la terminación de un flujo hacia `endpoint`, presentando el leaf de `host`.
    /// La arranca el llamante con `start`, igual que cualquier otra conexión saliente.
    ///
    /// - Parameters:
    ///   - host: el nombre del ClientHello, ya validado no vacío por la política. Decide dos cosas: el
    ///     leaf que se le presenta al cliente y el nombre contra el que se valida el certificado del
    ///     servidor real.
    ///   - endpoint: el destino **que eligió el dispositivo**. No se re-resuelve el nombre: inspeccionar
    ///     no puede cambiar con quién se habla.
    ///   - plaintext: sumidero del contenido descifrado, con su sentido. Nil = no se observa nada.
    ///   - onOutcome: el desenlace del intento, una sola vez, cuando el flujo termina.
    /// - Throws: si no se pudo construir (no se pudo emitir el leaf, no arrancó la pila). El llamante
    ///   lo trata como razón transitoria: passthrough intacto y **sin** marcar el flujo.
    func makeTermination(
        host: String,
        to endpoint: IPEndpoint,
        plaintext: (@Sendable (Data, Direction) -> Void)?,
        onOutcome: @escaping @Sendable (TLSTerminationOutcome) -> Void
    ) async throws -> any RelayConnection
}

/// Terminación e inspección TLS **opt-in** para flujos TCP contra el puerto 443, con consentimiento del
/// usuario vía la CA local.
///
/// Orquesta el núcleo puro (`TLSInterceptionPolicy`) y la cáscara inyectada (`TLSTerminationEngine`):
/// aplica las precondiciones residuales antes de tocar nada, delega la construcción de la terminación
/// en la cáscara, y traduce su desenlace a una decisión. Toda la lógica de decisión —incluido el
/// invariante de pinning del ADR 0003 (rechazo del cliente ⇒ `notInspectable` + passthrough, **sin
/// reintentos**)— vive en la política, así que el actor es una costura fina y testeable contra un doble.
///
/// Dos desviaciones conscientes sobre el boceto de la spec (`init(ca:reinject:)`,
/// `intercept(_ flow:clientHelloSNI:) async throws -> Result`):
///
/// 1. La CA y el I/O se mueven **dentro** de `TLSTerminationEngine`, y el actor recibe el motor ya
///    construido — el mismo movimiento que hizo `Relay.init` al ganar `connectionFactory`.
/// 2. `intercept` devolvía el desenlace de una vez porque el boceto lo creía síncrono de principio a
///    fin. No lo es: abrir la terminación y saber cómo acabó están separados por todo el flujo. Así que
///    `open` devuelve la conexión —el llamante la alimenta— y la decisión llega por `onResolve`. El
///    `LiveFlow` deja de hacer falta: lo único que se necesita del flujo es a dónde iba, y la clave
///    canónica no distingue quién de los dos extremos es el servidor.
public actor TLSInterceptor {

    private let engine: any TLSTerminationEngine
    /// Estado "CA generada + instalada + confiada", que solo la app conoce (el usuario instala el
    /// perfil en Ajustes). Se lee en cada intento porque puede cambiar en caliente (el usuario la
    /// retira mientras el túnel corre), y la reversibilidad exige respetarlo al instante.
    private let caReady: @Sendable () -> Bool

    public init(engine: any TLSTerminationEngine, caReady: @escaping @Sendable () -> Bool) {
        self.engine = engine
        self.caReady = caReady
    }

    /// Abre la terminación de un flujo candidato y devuelve la conexión que el llamante debe alimentar
    /// con el stream del dispositivo.
    ///
    /// `onResolve` entrega la decisión final cuando el flujo acaba: `.inspected`, `.notInspectable`
    /// (pinning — el llamante marca el flujo y **no** reintenta) o `.fail` con la razón transitoria.
    /// Ojo con lo que significa una razón transitoria **aquí**: a diferencia de las que aborta el gate,
    /// esta llega con la terminación ya en marcha, así que no hay flujo intacto que relayar — lo que se
    /// pierde es esa conexión, y el reintento del cliente entra como un flujo nuevo.
    ///
    /// - Throws: `TLSInterceptError` si las precondiciones residuales fallan (sin CA, sin SNI) o si el
    ///   motor no pudo construir la terminación. En los tres casos no se ha tocado la red y el llamante
    ///   relaya el flujo intacto y **sin** marcarlo.
    public func open(
        to endpoint: IPEndpoint,
        clientHelloSNI: String?,
        plaintext: (@Sendable (Data, Direction) -> Void)? = nil,
        onResolve: @escaping @Sendable (TLSInterceptionPolicy.Decision) -> Void
    ) async throws -> any RelayConnection {
        switch TLSInterceptionPolicy.gate(caReady: caReady(), clientHelloSNI: clientHelloSNI) {
        case .abort(let error):
            throw error
        case .attempt(let sni):
            do {
                return try await engine.makeTermination(
                    host: sni,
                    to: endpoint,
                    plaintext: plaintext,
                    onOutcome: { outcome in onResolve(TLSInterceptionPolicy.decide(outcome)) }
                )
            } catch let error as TLSInterceptError {
                throw error
            } catch {
                // Cualquier otro fallo de construcción es del stack: no hay leaf, o la pila no levantó.
                // Se colapsa aquí para que el llamante tenga un solo tipo de error que entender.
                throw TLSInterceptError.userspaceStackError
            }
        }
    }
}
