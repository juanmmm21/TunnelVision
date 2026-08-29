import Foundation
import Shared

/// Las dos costuras que necesita el enganche de la inspección al relay: por dónde el relay **pide**
/// una terminación TLS, y por dónde **cuenta** cómo acabó el intento.
///
/// Existen las dos por lo mismo que `SNIObserving` y `RelayConnectionFactory`: el relay es quien
/// tiene los bytes del flujo, pero ni decide la política de inspección (eso es de `TLSInterceptor`,
/// que es donde vive el ADR 0003) ni sabe nada de flujos guardados (eso es de la tabla que lleva el
/// pipeline). Un protocolo estrecho por cada dirección deja la mitad que decide corriendo en
/// Simulator contra dobles.

/// Quien construye la terminación TLS de un flujo candidato. La conformidad de producción es
/// `TLSInterceptor`, que aplica sus precondiciones antes de tocar nada y traduce el desenlace con
/// `TLSInterceptionPolicy`.
///
/// Lo que devuelve es un `RelayConnection` a secas **a propósito**: desde el relay una terminación no
/// se distingue de una conexión saliente, así que enganchar la inspección es cambiar *qué conexión se
/// crea* para un flujo y no abrir un segundo camino por dentro del relay.
public protocol FlowInspecting: Sendable {
    /// Abre la terminación de un flujo hacia `endpoint` presentando el leaf de `clientHelloSNI`.
    ///
    /// - Throws: una razón **transitoria** (sin CA, sin nombre, no se pudo emitir el leaf). El relay
    ///   la trata como manda la política: devuelve el flujo al passthrough con lo que hubiera
    ///   retenido y **sin** marcarlo, porque la causa puede desaparecer.
    func open(
        to endpoint: IPEndpoint,
        clientHelloSNI: String?,
        plaintext: (@Sendable (Data, Direction) -> Void)?,
        onResolve: @escaping @Sendable (TLSInterceptionPolicy.Decision) -> Void
    ) async throws -> any RelayConnection
}

/// `TLSInterceptor` ya tiene exactamente esta forma: la conformidad no añade nada porque la costura
/// se diseñó a su medida, y declararla es lo que evita que el relay importe al actor entero.
extension TLSInterceptor: FlowInspecting {}

/// Por dónde sale del relay el estado de inspección de un flujo: `inspected` cuando se descifró de
/// punta a punta, `notInspectable` cuando el cliente rechazó nuestro leaf (pinning).
///
/// Es el gemelo de `SNIObserving` y por la misma razón —el relay ve el desenlace, la tabla de flujos
/// es del pipeline—, pero **no se fundieron en un solo protocolo**: un nombre se lee del handshake en
/// claro y no dice nada de haber descifrado, y confundirlos pintaría de "inspeccionado" tráfico que
/// nadie ha mirado. Son dos hechos distintos sobre el mismo flujo y viajan por separado.
///
/// Es `async` por lo mismo que `SNIObserving`: quien lo implementa en producción es un actor
/// (`PacketPipeline`) y quien lo llama es otro (`Relay`).
public protocol TLSStatusObserving: Sendable {
    func observe(tlsStatus: TLSInspectionStatus, for key: FlowKey) async
}
