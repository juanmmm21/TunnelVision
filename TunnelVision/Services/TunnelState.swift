import Foundation

/// Estado del túnel tal y como lo reporta NetworkExtension, **sin importar NetworkExtension**.
///
/// Es un espejo Foundation-only de `NEVPNStatus`. Existe para que toda la capa de decisión de la app
/// (política, controlador, view models) sea pura y testeable en Simulator: quien traduce
/// `NEVPNStatus` a esto es la cáscara (`NETunnelProviderManagerAdapter`), el único sitio de la app
/// que importa el framework device-only.
public enum TunnelStatus: Sendable, Equatable {
    /// `NEVPNStatus.invalid`: todavía no hay perfil VPN guardado para esta app.
    case notInstalled
    case disconnected
    case connecting
    case connected
    /// El túnel está restableciéndose (cambio de red). Instalado y "encendido", pero sin cursar
    /// tráfico de forma fiable ahora mismo.
    case reasserting
    case disconnecting
}

/// Lo que la Dashboard pinta en su control de monitorización (`docs/ux/screens.md`).
///
/// No es el mismo enum que `TunnelStatus` a propósito: colapsa el detalle de transporte que al
/// usuario no le dice nada e incorpora los desenlaces que NetworkExtension **no** reporta como
/// status sino como error lanzado (denegar el diálogo del sistema, un arranque fallido). Que el
/// fallo sea un valor del estado —y no una excepción que se pierde en un log— es lo que permite a la
/// vista ofrecer el "Try again" que exige `docs/ux/onboarding-and-consent.md`: nunca un callejón sin
/// salida.
public enum TunnelState: Sendable, Equatable {
    /// No hay perfil VPN: la UI invita a instalarlo (primer arranque).
    case notInstalled
    /// Instalado y parado.
    case off
    /// Arrancando o restableciéndose.
    case starting
    /// Monitorizando.
    case live
    case stopping
    /// Algo falló y el usuario puede hacer algo al respecto.
    case failed(TunnelControlError)
}

/// Errores del control del túnel. Tipados y exhaustivos: la cáscara traduce cualquier `NSError` de
/// NetworkExtension a uno de estos, así que nada por encima de ella ve un error sin tipo.
public enum TunnelControlError: Error, Sendable, Equatable {
    /// El usuario pulsó "Don't Allow" en el diálogo del sistema al guardar la configuración VPN.
    case permissionDenied
    /// Fallo al cargar o guardar el perfil VPN, con el texto del sistema para poder enseñarlo.
    case configurationFailed(String)
    /// El perfil está guardado pero el túnel no arrancó.
    case startFailed(String)
    /// Se pidió arrancar sin perfil guardado.
    case notInstalled
    /// No hay sesión viva al otro lado del canal de control. No es una avería: es la carrera normal
    /// entre un gesto en la UI y un túnel que ya se paró.
    case notRunning
    /// El envío por el canal de control falló en el transporte.
    case controlChannelFailed(String)
    /// La extensión contestó algo que no es un `ControlResponse` (versión distinta, emisor ajeno).
    case malformedResponse
}

extension TunnelControlError {
    /// Dominio de los errores de NetworkExtension. Se compara como texto para no importar el
    /// framework aquí; la cáscara pasa `nsError.domain` tal cual.
    public static let vpnErrorDomain = "NEVPNErrorDomain"

    /// `NEVPNError.configurationReadWriteFailed`. Es lo que devuelve `saveToPreferences` cuando el
    /// usuario deniega el diálogo del sistema, y por eso merece un estado propio: la UI no puede
    /// tratar un "no quiero" como una avería.
    public static let vpnConfigurationReadWriteFailedCode = 5

    /// Clasifica un `NSError` de NetworkExtension a partir de sus campos, sin importarla.
    public static func classifying(domain: String, code: Int, message: String) -> TunnelControlError {
        guard domain == vpnErrorDomain, code == vpnConfigurationReadWriteFailedCode else {
            return .configurationFailed(message)
        }
        return .permissionDenied
    }
}

/// Las dos decisiones del control del túnel, puras y por tanto testeables sin dispositivo.
public enum TunnelStatePolicy {

    /// Estado a partir de un status recién cargado, sin historia previa.
    public static func state(for status: TunnelStatus) -> TunnelState {
        switch status {
        case .notInstalled:
            return .notInstalled
        case .disconnected:
            return .off
        case .connecting, .reasserting:
            // `reasserting` es "arrancando", no "en marcha": mientras se restablece no cursa tráfico
            // de forma fiable, y decir "monitorizando" ahí sería una mentira que el usuario pilla.
            return .starting
        case .connected:
            return .live
        case .disconnecting:
            return .stopping
        }
    }

    /// Estado siguiente ante un cambio de status.
    ///
    /// Conserva un fallo visible: NetworkExtension acompaña casi todos los fallos de un
    /// `disconnected`, así que mapearlo sin más borraría el error justo cuando la UI iba a
    /// enseñarlo. Un `.failed` solo lo levanta un status **activo** (el túnel arrancó de verdad) o
    /// un reintento explícito del usuario, que el controlador materializa fijando el estado él mismo.
    public static func next(from current: TunnelState, status: TunnelStatus) -> TunnelState {
        let mapped = state(for: status)
        guard case .failed = current else { return mapped }
        switch mapped {
        case .starting, .live:
            return mapped
        case .notInstalled, .off, .stopping, .failed:
            return current
        }
    }
}
