import Foundation

/// Cuánto puede guardar un `ResolvedNameMap` y durante cuánto.
///
/// **Ninguno de los cuatro números tiene valor por defecto**: cada uno decide algo —cuánta memoria de
/// la extensión se lleva el mapa, cuánto tiempo se le sigue creyendo a una respuesta— y un número que
/// decide no se queda escondido en una firma. Los que usa el túnel están en `tunnel`, con su porqué.
public struct ResolvedNameLimits: Sendable, Hashable {

    /// Cuántos pares dirección-nombre caben en total. Es el tope de memoria del mapa.
    public let capacity: Int

    /// Cuántos nombres se recuerdan para **una** dirección. Una IP de CDN sirve a muchos; pasado este
    /// número se olvida el que hace más que se resolvió.
    public let namesPerAddress: Int

    /// Lo mínimo que vale una respuesta, en segundos, diga lo que diga su TTL.
    public let minimumLifetime: UInt32

    /// Lo máximo que vale, en segundos.
    public let maximumLifetime: UInt32

    /// Precondición: caben al menos un par y un nombre por dirección, y el mínimo no supera al máximo.
    /// Unos límites que no dejan guardar nada son un error de quien los escribe, no un dato.
    public init(capacity: Int, namesPerAddress: Int, minimumLifetime: UInt32, maximumLifetime: UInt32) {
        precondition(capacity >= 1, "ResolvedNameLimits necesita capacidad para al menos un par")
        precondition(namesPerAddress >= 1, "ResolvedNameLimits necesita al menos un nombre por dirección")
        precondition(
            minimumLifetime <= maximumLifetime,
            "ResolvedNameLimits: el mínimo (\(minimumLifetime) s) supera al máximo (\(maximumLifetime) s)"
        )
        self.capacity = capacity
        self.namesPerAddress = namesPerAddress
        self.minimumLifetime = minimumLifetime
        self.maximumLifetime = maximumLifetime
    }

    /// Los límites con los que el túnel nombra flujos.
    ///
    /// - **2048 pares** son, en el peor caso —nombres de 253 bytes—, menos de 1 MB, dentro de una
    ///   extensión que vive con un presupuesto de memoria fijo. Un teléfono resuelve del orden de
    ///   cientos de nombres por hora, así que en la práctica el tope no se toca.
    /// - **Cuatro nombres por dirección**: bastan para decir que una IP es compartida y cuáles eran
    ///   los candidatos; más allá la lista deja de ser un dato que un evaluador pueda leer.
    /// - **Un minuto de suelo**: hay respuestas con TTL 0 o de un segundo (balanceadores que no
    ///   quieren caché), y la conexión para la que se preguntó llega después, no en el mismo instante.
    ///   Sin suelo, justo esos flujos se quedarían sin nombre.
    /// - **Un día de techo**: un TTL es un entero de 32 bits y nada impide que diga 136 años. Una
    ///   dirección no es de quien era ayer con la certeza que hace falta para firmar un informe.
    public static let tunnel = ResolvedNameLimits(
        capacity: 2048,
        namesPerAddress: 4,
        minimumLifetime: 60,
        maximumLifetime: 86_400
    )
}

/// El nombre que el dispositivo había pedido para una dirección, según las respuestas de DNS que
/// pasaron por el túnel.
///
/// **No es un SNI.** Un SNI lo anuncia la propia conexión; esto es una deducción —«la última vez que
/// el dispositivo preguntó por un nombre y le contestaron esta dirección, el nombre era éste»—, y por
/// eso viaja con cuándo se resolvió y con los otros nombres que la misma dirección tenía vivos.
public struct ResolvedName: Sendable, Hashable {

    /// El nombre **por el que se preguntó**, normalizado (minúsculas, sin punto final). No el final de
    /// una cadena de CNAME: lo que una allowlist autoriza es lo que la app pidió, no dónde lo aloja
    /// quien se lo sirve.
    public let name: String

    /// Cuándo pasó la respuesta, en el reloj que sella los paquetes (`PacketMeta.timestamp`).
    public let resolvedAt: UInt64

    /// Los demás nombres vivos de la misma dirección, del más reciente al más antiguo. Vacío es que
    /// la atribución no tiene competencia; con algo dentro, la dirección es compartida y `name` es el
    /// candidato más probable, no el único.
    public let otherNames: [String]

    public init(name: String, resolvedAt: UInt64, otherNames: [String]) {
        self.name = name
        self.resolvedAt = resolvedAt
        self.otherNames = otherNames
    }
}

/// Qué hizo el mapa con un mensaje.
///
/// Es un valor y no un `Void` porque **«no hubo nada que leer» es un resultado que hay que poder
/// contar**: con DNS cifrado no pasa ninguna respuesta por el puerto 53, y un flujo sin nombre tiene
/// que poder explicarse en vez de quedarse en blanco.
public enum DNSNameIngestion: Sendable, Hashable {

    /// Se apuntaron tantas direcciones para el nombre de la pregunta.
    case recorded(addresses: Int)

    case ignored(Reason)

    public enum Reason: Sendable, Hashable {
        /// Una consulta: todavía no contesta nada.
        case notAResponse
        /// Un opcode que no es la consulta estándar (NOTIFY, UPDATE…): sus secciones significan otra cosa.
        case unsupportedOpcode
        /// El servidor contestó un error (NXDOMAIN, SERVFAIL…). Lo que traiga no nombra nada.
        case errorResponse
        /// No trae exactamente una pregunta de clase IN, así que no hay un nombre al que atribuir.
        case unsupportedQuestion
        /// El nombre de la pregunta no es un nombre de host: la raíz, un byte escapado, un comodín.
        case unusableName
        /// Una respuesta legítima sin direcciones para ese nombre (solo CNAME, TXT, HTTPS…).
        case noAddresses
    }
}

/// El mapa dirección → nombre con el que se le pone nombre a un flujo que no lo anuncia: QUIC, lo que
/// no es TLS, y en general todo lo que el escáner del ClientHello no alcanza.
///
/// Es un **valor puro**: no lee el reloj (el instante se le pasa, y es el sello monotónico de los
/// paquetes), no toca disco y no sabe de flujos. Su dueño le da los mensajes de DNS que ve pasar y le
/// pregunta por una dirección.
///
/// **Qué entra.** Solo respuestas sin error a una única pregunta de clase IN, y de ellas solo las
/// direcciones (A y AAAA) **alcanzables desde el nombre de la pregunta** siguiendo los CNAME de la
/// propia respuesta. Un registro de dirección cuyo dueño no es ese nombre ni uno de sus alias no se
/// apunta: no contesta a lo que se preguntó, y apuntarlo sería dejar que un mensaje nombrase
/// direcciones que no son suyas.
///
/// **Cuándo caduca.** Cada par vale el TTL más corto del camino que lleva del nombre a la dirección
/// —el de su registro y el de cada CNAME intermedio—, acotado por `ResolvedNameLimits`. Volver a ver
/// la misma respuesta lo renueva. Un par caducado no nombra nada: una dirección de CDN se recicla, y
/// atribuirla a quien la tuvo es peor que decir que no se sabe.
///
/// **Cómo se desempata.** Una dirección puede tener varios nombres vivos a la vez. Gana **el que se
/// resolvió más recientemente**, porque un dispositivo pregunta justo antes de conectar; a igualdad
/// de instante, el menor en orden alfabético, para que la respuesta no dependa del orden de un
/// diccionario. Los demás no se callan: van en `ResolvedName.otherNames`.
///
/// **Cuánto ocupa.** Nunca más de `limits.capacity` pares. Al llenarse se van primero los caducados y
/// después el que hace más que se resolvió.
///
/// ADR 0003 no entra en juego: son respuestas en claro que el dispositivo de su dueño recibió.
public struct ResolvedNameMap: Sendable {

    public let limits: ResolvedNameLimits

    private struct Entry: Sendable {
        let name: String
        let resolvedAt: UInt64
        let expiresAt: UInt64
    }

    /// Por dirección, sus nombres del más reciente al más antiguo (y, a igualdad, por orden
    /// alfabético): el primero vivo es la respuesta.
    private var entries: [IPAddress: [Entry]] = [:]

    /// Los pares guardados, caducados incluidos hasta que algo los barre.
    public private(set) var count: Int = 0

    /// La clase IN. Otra clase (CHAOS, Hesiod) no habla de direcciones de internet.
    private static let internetClass: UInt16 = 1

    /// Cuántos CNAME se siguen como mucho desde el nombre de la pregunta. Es un tope de trabajo; una
    /// cadena real tiene dos o tres eslabones.
    private static let maximumAliasHops = 16

    private static let nanosecondsPerSecond: UInt64 = 1_000_000_000

    public init(limits: ResolvedNameLimits) {
        self.limits = limits
    }

    // MARK: - Entrada

    /// Apunta lo que un mensaje de DNS dice sobre qué direcciones tiene el nombre por el que se preguntó.
    ///
    /// - Parameter instant: cuándo pasó el mensaje, en nanosegundos del reloj que sella los paquetes.
    @discardableResult
    public mutating func ingest(_ message: DNSMessage, at instant: UInt64) -> DNSNameIngestion {
        guard message.isResponse else { return .ignored(.notAResponse) }
        guard message.opcode == 0 else { return .ignored(.unsupportedOpcode) }
        guard message.responseCode == .noError else { return .ignored(.errorResponse) }
        guard message.questions.count == 1, let question = message.questions.first,
              question.recordClass == Self.internetClass else {
            return .ignored(.unsupportedQuestion)
        }
        guard let name = Self.hostname(from: question.name) else { return .ignored(.unusableName) }

        let aliases = Self.aliases(of: name, in: message.answers)

        // Una misma dirección puede venir dos veces en una respuesta; se queda con el TTL más corto,
        // que es el que de verdad acota cuánto vale lo que se contestó.
        var lifetimes: [IPAddress: UInt32] = [:]
        for record in message.answers where record.recordClass == Self.internetClass {
            guard case .address(let address) = record.data,
                  let aliasLifetime = aliases[Self.comparable(record.name)] else { continue }
            let lifetime = min(aliasLifetime, record.timeToLive)
            lifetimes[address] = min(lifetimes[address] ?? lifetime, lifetime)
        }
        guard !lifetimes.isEmpty else { return .ignored(.noAddresses) }

        // En orden de dirección, para que lo que se desaloja al llenarse no dependa del diccionario.
        for (address, lifetime) in lifetimes.sorted(by: { $0.key < $1.key }) {
            record(name, for: address, resolvedAt: instant, expiresAt: expiry(of: lifetime, from: instant))
        }
        return .recorded(addresses: lifetimes.count)
    }

    /// Olvida los pares que ya han caducado. Devuelve cuántos se fueron.
    ///
    /// El mapa los barre él solo cuando se llena; esto es para quien quiera devolver la memoria antes.
    @discardableResult
    public mutating func removeExpired(at instant: UInt64) -> Int {
        let before = count
        for (address, names) in entries {
            let live = names.filter { $0.expiresAt > instant }
            guard live.count != names.count else { continue }
            entries[address] = live.isEmpty ? nil : live
            count -= names.count - live.count
        }
        return before - count
    }

    // MARK: - Consulta

    /// El nombre que el dispositivo había pedido para esa dirección y sigue vivo en ese instante, o
    /// `nil` si no hay ninguno: nunca se vio una respuesta con ella, o la que se vio ya caducó.
    public func name(for address: IPAddress, at instant: UInt64) -> ResolvedName? {
        guard let names = entries[address] else { return nil }
        let live = names.filter { $0.expiresAt > instant }
        guard let winner = live.first else { return nil }
        return ResolvedName(
            name: winner.name,
            resolvedAt: winner.resolvedAt,
            otherNames: live.dropFirst().map(\.name)
        )
    }

    // MARK: - Lo que decide

    /// Un nombre del parser pasado a nombre de host comparable, o `nil` si no lo es.
    ///
    /// La vara de medir es `DomainPattern`: **un nombre se guarda solo si podría escribirse como una
    /// entrada exacta de la allowlist**, que es contra lo que se va a comparar. Eso deja fuera, sin
    /// más reglas aquí, la raíz, un nombre con bytes escapados (`\032`) y el comodín literal.
    private static func hostname(from presented: String) -> String? {
        guard let pattern = try? DomainPattern(parsing: presented), pattern.scope == .exact else {
            return nil
        }
        return pattern.name
    }

    /// La forma con la que se comparan entre sí los nombres de un mismo mensaje. El DNS no distingue
    /// mayúsculas, y un resolutor puede devolver la pregunta con las suyas cambiadas a propósito
    /// (la aleatorización 0x20), así que el dueño de un registro y la pregunta se comparan en minúsculas.
    private static func comparable(_ presented: String) -> String {
        presented.lowercased()
    }

    /// Los nombres que la respuesta declara alias del de la pregunta —él mismo incluido—, cada uno
    /// con el TTL más corto del camino de CNAME que lleva hasta él.
    ///
    /// Se recorre la cadena desde la pregunta en vez de fiarse del orden de los registros: el orden
    /// es costumbre de los resolutores, no una garantía del formato.
    private static func aliases(of name: String, in answers: [DNSResourceRecord]) -> [String: UInt32] {
        var targets: [String: (name: String, timeToLive: UInt32)] = [:]
        for record in answers where record.type == .cname && record.recordClass == internetClass {
            guard case .name(let target) = record.data else { continue }
            let owner = comparable(record.name)
            // Un nombre tiene un solo CNAME; si la respuesta trae dos, vale el primero.
            if targets[owner] == nil {
                targets[owner] = (comparable(target), record.timeToLive)
            }
        }

        var reached: [String: UInt32] = [name: .max]
        var current = name
        var lifetime = UInt32.max
        for _ in 0..<maximumAliasHops {
            guard let next = targets[current], reached[next.name] == nil else { break }
            lifetime = min(lifetime, next.timeToLive)
            reached[next.name] = lifetime
            current = next.name
        }
        return reached
    }

    /// Cuándo deja de valer algo resuelto en `instant` con ese TTL, ya acotado por los límites.
    private func expiry(of timeToLive: UInt32, from instant: UInt64) -> UInt64 {
        let seconds = min(max(timeToLive, limits.minimumLifetime), limits.maximumLifetime)
        let (expiry, overflow) = instant.addingReportingOverflow(UInt64(seconds) * Self.nanosecondsPerSecond)
        return overflow ? .max : expiry
    }

    private mutating func record(_ name: String, for address: IPAddress, resolvedAt: UInt64, expiresAt: UInt64) {
        var names = entries[address] ?? []

        if let existing = names.firstIndex(where: { $0.name == name }) {
            names.remove(at: existing)
            count -= 1
        } else if count >= limits.capacity {
            // Hay que hacer sitio, y puede que el par que se vaya sea de esta misma dirección.
            makeRoom(at: resolvedAt)
            names = entries[address] ?? []
        }

        names.append(Entry(name: name, resolvedAt: resolvedAt, expiresAt: expiresAt))
        names.sort { lhs, rhs in
            lhs.resolvedAt != rhs.resolvedAt ? lhs.resolvedAt > rhs.resolvedAt : lhs.name < rhs.name
        }
        count += 1

        if names.count > limits.namesPerAddress {
            names.removeLast()
            count -= 1
        }
        entries[address] = names
    }

    /// Deja al menos un hueco: primero lo caducado, y si no basta, el par que hace más que se resolvió.
    private mutating func makeRoom(at instant: UInt64) {
        removeExpired(at: instant)
        guard count >= limits.capacity else { return }

        // A igualdad de instante desempata la dirección: sin ello, cuál se va dependería del orden
        // del diccionario y dos pasadas con los mismos mensajes darían mapas distintos.
        var oldest: (address: IPAddress, resolvedAt: UInt64)?
        for (address, names) in entries {
            guard let last = names.last else { continue }
            if let candidate = oldest,
               (candidate.resolvedAt, candidate.address) <= (last.resolvedAt, address) { continue }
            oldest = (address, last.resolvedAt)
        }
        guard let victim = oldest, var names = entries[victim.address] else { return }
        names.removeLast()
        entries[victim.address] = names.isEmpty ? nil : names
        count -= 1
    }
}
