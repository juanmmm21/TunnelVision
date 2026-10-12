import Foundation

/// Cuánto le dedica el pipeline a leer el nombre de los flujos QUIC: lo que se mira de cada uno y
/// cuántos se pueden estar mirando a la vez.
///
/// Sin valores por defecto, por lo mismo que los topes que lleva dentro: los dos acotan memoria
/// de la extensión, y cuánta vale el nombre de un flujo es una decisión que tiene que verse.
public struct QUICNameReadLimits: Sendable, Equatable {

    /// Lo que se mira de un flujo y lo que puede retener mientras tanto.
    public let perFlow: QUICClientHelloReader.Limits

    /// Flujos con una lectura a medias a la vez. Con el cupo lleno, el Initial de un flujo nuevo
    /// no se mira —se cuenta— y el flujo se queda con el nombre que le diera el DNS.
    public let maxConcurrentReads: Int

    public init(perFlow: QUICClientHelloReader.Limits, maxConcurrentReads: Int) {
        self.perFlow = perFlow
        self.maxConcurrentReads = maxConcurrentReads
    }

    /// Los del túnel. Una lectura dura lo que tardan en pasar los dos primeros datagramas de una
    /// conexión, así que a la vez solo hay las de las conexiones que se están abriendo en ese
    /// instante: una página que tira de muchos orígenes abre unas pocas decenas. 64 lecturas, con
    /// lo que cada una puede retener como mucho (dos veces 8 192 bytes), son 1 MB en el peor caso
    /// —y ese caso es un tráfico escrito a propósito para llenarlo—.
    public static let tunnel = QUICNameReadLimits(perFlow: .tunnel, maxConcurrentReads: 64)
}
