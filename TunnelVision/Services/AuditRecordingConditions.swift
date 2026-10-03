import Foundation
import Shared
import UIKit

/// De dónde salen las condiciones que una sesión de auditoría declara al abrirse: el dispositivo, el
/// sistema, la versión de la herramienta y el estado de la inspección TLS.
///
/// Se leen **al abrir la sesión y no se preguntan**: son hechos del dispositivo, y un evaluador que
/// tuviera que teclear el modelo o si la CA está confiada los escribiría mal una de cada tantas
/// veces — en una evidencia que luego nadie puede reproducir sin ellos.
public enum AuditRecordingConditions {

    /// El entorno de este dispositivo.
    @MainActor
    public static func environment(bundle: Bundle = .main) -> AuditEnvironment {
        AuditEnvironment(
            deviceModel: deviceModel(),
            osVersion: UIDevice.current.systemVersion,
            toolVersion: toolVersion(
                marketing: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            )
        )
    }

    /// La versión de la herramienta como va en el informe: `1.0.0 (1)`. Sin número de build se queda
    /// en la versión, y sin ninguno de los dos se dice que no se sabe en vez de dejar un hueco — un
    /// campo vacío en una evidencia se lee como un dato que se perdió.
    public static func toolVersion(marketing: String?, build: String?) -> String {
        switch (marketing, build) {
        case (let marketing?, let build?): "\(marketing) (\(build))"
        case (let marketing?, nil): marketing
        case (nil, let build?): "(\(build))"
        case (nil, nil): "unknown"
        }
    }

    /// El identificador de modelo del hardware (`iPhone18,3`), que es lo que distingue dos
    /// dispositivos del mismo nombre comercial. En el Simulator `uname` devuelve la arquitectura del
    /// Mac, así que allí se lee el modelo simulado de su entorno.
    @MainActor
    public static func deviceModel(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
            return simulated
        }
        var info = utsname()
        guard uname(&info) == 0 else { return UIDevice.current.model }
        let machine = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }

    /// En qué condiciones de inspección se abre una sesión, a partir de lo que ya saben el almacén
    /// de ajustes y la evaluación de confianza de la CA.
    ///
    /// Unos ajustes ilegibles cuentan como inspección **apagada**: es lo que la extensión hace con
    /// ellos al arrancar, y declarar lo contrario haría que el informe leyera pinning donde no hubo
    /// handshake contra la CA local.
    public static func inspection(
        loadSettings: @Sendable () throws -> AppSettings,
        availability: TLSInspectionAvailability
    ) -> InspectionConditions {
        let enabled: Bool
        do {
            enabled = try loadSettings().tlsInspectionEnabled
        } catch {
            enabled = false
        }
        return InspectionConditions(inspectionEnabled: enabled, caTrusted: availability == .ready)
    }
}
