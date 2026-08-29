import Foundation
import Shared

// Conformidades de los sumideros reales a los protocolos del pipeline. Viven en su propio fichero
// porque son el único punto de M7 que ata el pipeline a GRDB (vía `FlowStore`): así el paquete
// SwiftPM desechable que valida la lógica en este entorno puede excluirlas y prescindir de GRDB.
//
// Ninguna es retroactiva en el sentido problemático: los protocolos son de este módulo, así que
// nadie más puede declarar estas conformidades.

/// El productor del ring ya cumple el contrato: `push` no bloquea y absorbe el desbordamiento
/// contándolo.
extension RingBufferProducer: LiveFeedSink {}

/// `PcapWriter` es un actor: sus métodos `throws` satisfacen los requisitos `async throws` del
/// protocolo, porque llamarlos desde fuera del actor ya es asíncrono.
extension PcapWriter: CaptureSink {}

/// `PlaintextWriter` es un actor, como el de capturas: sus métodos síncronos satisfacen los
/// requisitos `async` del protocolo porque llamarlos desde fuera del actor ya es asíncrono.
extension PlaintextWriter: PlaintextSink {}

extension FlowStore: FlowPersisting {}
