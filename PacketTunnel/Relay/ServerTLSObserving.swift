import Foundation
import Shared

/// Por dónde sale del relay lo que el **servidor contestó** al ClientHello de un flujo: la versión
/// y la suite de su ServerHello, o la alerta con la que se negó.
///
/// Es la costura simétrica a `SNIObserving`, para el otro sentido del mismo handshake, y existe por
/// lo mismo: el relay tiene el stream entrante en orden —es quien lo recibe de la conexión saliente,
/// antes de re-segmentarlo hacia el dispositivo— pero la tabla de flujos es del pipeline.
///
/// **No se fundió con `SNIObserving`** aunque las dos lean el mismo handshake: el nombre lo dice el
/// cliente y esto lo dice el servidor, llegan en momentos distintos y uno puede existir sin el otro
/// (un ClientHello sin SNI recibe ServerHello igual). Un solo protocolo obligaría a esperar al
/// segundo para contar el primero.
///
/// Es `async` por la misma razón que sus hermanas, y como `SNIObserving` se llama **una sola vez por
/// lectura**: en cuanto el escáner decide. Lo que no es una respuesta sobre TLS —un stream que no
/// era un handshake, un mensaje ilegible— no pasa por aquí: se cuenta en `RelayStats` y el flujo se
/// queda sin nada apuntado.
///
/// **La cadena de certificados sale por la misma costura**, y no por una propia como la oferta del
/// cliente: la dice el mismo extremo, en el mismo vuelo del handshake, y no existe sin un
/// ServerHello delante. Llega aparte de la versión —y puede no llegar— porque viene detrás en el
/// stream: quien observa no debe esperar a una para apuntar la otra.
public protocol ServerTLSObserving: Sendable {
    func observe(serverTLS: ServerTLSAnswer, for key: FlowKey) async
    func observe(serverCertificates: ServerCertificateReading, for key: FlowKey) async
}
