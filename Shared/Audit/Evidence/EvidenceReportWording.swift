import Foundation

/// Lo que el informe (`report.pdf`) dice y los demás documentos del paquete no: sus títulos, sus
/// rótulos y una frase por cada motivo por el que una comprobación no pudo mirar un flujo.
///
/// Sigue en `EvidenceWording` porque la regla es la misma: lo que se observó y ni una palabra
/// más. Los motivos tienen frase aquí —en `findings.json` van como identificador con sus
/// detalles— porque un informe se lee sin el JSON al lado. Lo que el paquete ya redacta (las
/// notas, lo que afirma un hallazgo, lo que dice un veredicto) el informe lo **cita**.
extension EvidenceWording {

    // MARK: - Títulos

    public static let reportTitle = "Network evidence report"

    public static func reportSectionTitle(_ kind: EvidenceReportSectionKind) -> String {
        switch kind {
        case .session: return "Session"
        case .method: return "How to read this report"
        case .catalogue: return "Requirement catalogue"
        case .requirements: return "Requirements"
        case .findings: return "Findings"
        case .checks: return "How far each check got"
        case .tlsReadings: return "TLS and QUIC readings"
        case .capture: return "Capture"
        }
    }

    public static func reportCheckTitle(_ check: FindingsCheck) -> String {
        switch check {
        case .encryption: return "Encryption (encryption)"
        case .tlsVersion: return "TLS version (tlsVersion)"
        case .host: return "Destination against the allowlist (host)"
        case .pinning: return "Certificate pinning (pinning)"
        case .consent: return "Activity before consent (consent)"
        }
    }

    // MARK: - La sesión

    /// Lo que una sesión deja leer sobre pinning. Va siempre: un resultado de pinning de una
    /// sesión sin la CA confiada no significa nada, y el informe tiene que decirlo en vez de callar.
    public static func reportPinningConditions(supportsPinningEvidence: Bool) -> String {
        supportsPinningEvidence
            ? "Inspection was on and the local CA was trusted: whether a connection accepted or "
                + "refused the local CA's certificate can be read from this session."
            : "Nothing about certificate pinning can be read from this session: that takes "
                + "inspection on and the local CA trusted while it is recorded."
    }

    public static let reportNoMarkers =
        "No marker was placed in this session. Without a consent marker, nothing is stated about "
        + "activity before consent."

    public static let reportNoAllowlist =
        "The project has no allowlist. Named connections are not compared with one, and none is "
        + "reported as unexpected."

    // MARK: - Hallazgos y comprobaciones

    /// Con cero hallazgos. Que no haya ninguno no dice que no haya nada: lo dice la sección de
    /// las comprobaciones, y esta frase manda allí.
    public static let reportNoFindings =
        "No finding was raised in this session. That states what was looked at, not that nothing "
        + "is wrong: the next section says how many connections each check could look at."

    public static let reportChecksIntroduction =
        "Each check sorts every connection of the session into one of four groups: it is behind a "
        + "finding, it was looked at with nothing to report, it could not be assessed (with the "
        + "reason), or the check does not apply to it. A requirement names the check behind it."

    /// El rótulo de los flujos en los que una comprobación pudo mirar y no encontró nada.
    /// `nil` en pinning: allí el desenlace favorable también es un hallazgo y el grupo está
    /// siempre vacío, así que un cero con este rótulo se leería como una observación.
    public static func reportLookedAtLabel(_ check: FindingsCheck) -> String? {
        switch check {
        case .encryption: return "Connections seen to be encrypted"
        case .tlsVersion: return "Connections at or above the minimum TLS version"
        case .host: return "Connections to a host the allowlist covers"
        case .pinning: return nil
        case .consent: return "Connections opened after every consent marker"
        }
    }

    public static let reportPinningOutcomesNote =
        "Both outcomes of this check are findings: a connection that accepted the local CA's "
        + "certificate and one that refused it are each listed under Findings, per host."

    /// Una versión de TLS como se nombra en una frase: su nombre publicado o, si no lo tiene, el
    /// valor del cable.
    public static func reportName(of version: TLSProtocolVersion) -> String {
        reportName(of: EvidenceTLSVersion(version))
    }

    public static func reportName(of version: EvidenceTLSVersion) -> String {
        if let name = version.name { return name }
        let hex = String(version.wireValue, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    /// De dónde sale una versión de TLS, con el identificador que lleva en `flows.json` y en
    /// `findings.json`.
    public static func reportBasis(_ observation: EvidenceTLSObservation) -> String {
        if observation.fromHelloRetryRequest == true {
            return "\(observation.basis), from a HelloRetryRequest"
        }
        if let quic = observation.quicVersion {
            return "\(observation.basis) \(quic.hex)"
        }
        return observation.basis
    }

    public static func reportReason(_ gap: TLSVersionGap) -> String {
        switch gap {
        case .serverAnswerNotRead:
            return "The connection shows signs of TLS, but no answer from the server was read."
        case .serverRefused(let alert):
            return "The server answered with an alert (code \(alert)): no version was negotiated."
        case .unrecognisedVersion(let observation):
            let written = EvidenceTLSObservation(observation)
            return "The version read (\(reportName(of: written.version)), \(reportBasis(written))) "
                + "is not a published TLS version and cannot be compared with the minimum."
        case .appNegotiationNotObserved(let upstream, let offer):
            return "The server negotiated \(reportName(of: upstream)) with the tunnel's own "
                + "connection. What the app would have negotiated was not observed: "
                + reportReason(offer)
        case .quicVersionOnlyProposed(let version):
            return "The QUIC version (\(EvidenceWireCode(version).hex)) was read only from the "
                + "client, which proposes it: the server may have changed it."
        case .unrecognisedQUICVersion(let version):
            return "The QUIC version (\(EvidenceWireCode(version).hex)) is not one whose TLS "
                + "version is known."
        }
    }

    private static func reportReason(_ offer: ClientOfferGap) -> String {
        switch offer {
        case .notRead:
            return "its ClientHello was not read."
        case .encryptedClientHello:
            return "its ClientHello carried Encrypted Client Hello, so the offer that was read "
                + "may not be the real one."
        case .ceilingOnly(let ceiling):
            return "its ClientHello gave only a ceiling (up to \(reportName(of: ceiling))), not "
                + "the list of versions it accepts."
        case .listsWeakerVersion:
            return "its ClientHello also listed a version below the minimum."
        case .listNotConclusive:
            return "the versions its ClientHello listed cannot be ordered."
        }
    }

    public static func reportReason(_ gap: EncryptionGap) -> String {
        switch gap {
        case .unrecognisedOpening:
            return "The TCP stream opened with something that is neither TLS nor HTTP. Nothing "
                + "is stated about it either way."
        case .openingNotRead:
            return "The opening of the TCP stream was not read. A port number alone states nothing."
        case .unrecognisedQUICVersion(let version):
            return "The QUIC version (\(EvidenceWireCode(version).hex)) is not one known to "
                + "encrypt what it carries."
        case .datagramsNotRead:
            return "A UDP connection with no recognised QUIC header. Its datagrams are not read "
                + "beyond that; DNS on port 53 is counted here."
        }
    }

    public static func reportReason(_ gap: HostGap) -> String {
        switch gap {
        case .allowlistEmpty:
            return "The project has no allowlist to compare the name with."
        case .candidatesDisagree(let attributedNameAllowed):
            return "The name was deduced from a DNS reply, and its address was shared by names "
                + "inside and outside the allowlist. The name attributed to the connection is "
                + (attributedNameAllowed ? "inside it." : "outside it.")
        }
    }

    public static func reportReason(_ gap: PinningGap) -> String {
        switch gap {
        case .inspectionOff:
            return "The session was recorded with inspection off."
        case .caNotTrusted:
            return "Inspection was on and the local CA was not trusted: every app refuses it, so "
                + "a refusal states nothing."
        case .quicNotInspected:
            return "The connection is QUIC. Inspection only terminates TLS over TCP."
        case .noInspectionOutcome:
            return "The connection shows TLS over TCP and carries no inspection outcome: "
                + "inspection was not attempted on it, or its result is not known."
        case .outcomeWithoutAnnouncedName:
            return "The connection carries an inspection outcome but not the name it announced, "
                + "so the host of the observation is not known."
        }
    }

    public static func reportReason(_ gap: ConsentGap) -> String {
        switch gap {
        case .noConsentMarker:
            return "The session has no consent marker."
        case .betweenConsentMarkers:
            return "The connection opened between the first and the last consent marker of the "
                + "session."
        }
    }

    // MARK: - Lecturas de TLS

    public static let reportTLSReadingsNote =
        "One row per host and reading, in the order each was first seen. The last column names "
        + "where the reading comes from, as flows.json does: serverHello is the server's answer to "
        + "the app's own ClientHello; upstreamConnection is what the server negotiated with the "
        + "tunnel's own connection on an inspected connection, not with the app; a QUIC version "
        + "read from the client is the one it proposed. Nothing about a certificate was validated."

    // MARK: - La captura

    public static func reportCaptureStanding(_ standing: EvidenceCaptureStanding) -> String {
        switch standing {
        case .nothingRecorded:
            return "The session recorded no packets: capture.pcapng opens and is empty."
        case .complete:
            return "Every packet the session recorded is in capture.pcapng."
        case .incomplete:
            return "capture.pcapng does not hold every packet the session recorded. A connection "
                + "with few packets in it is not a connection with little traffic: the counts "
                + "below, and capture.json for each connection, say what is not there."
        }
    }

    /// El rótulo de un motivo, con la clave que lleva en `capture.json`: es con la que la nota
    /// de la captura, que el informe cita, lo define.
    public static func reportLabel(_ loss: EvidencePacketLoss) -> String {
        switch loss {
        case .notCaptured: return "Never written to a capture file (notCaptured)"
        case .captureFileMissing: return "In a capture file no longer on the device (captureFileMissing)"
        case .recordUnreadable: return "Not readable back from its capture file (recordUnreadable)"
        }
    }

    // MARK: - El pie de página

    /// Con el total: una hoja suelta de un expediente dice de cuántas es.
    public static func reportPageLabel(_ number: Int, of count: Int) -> String {
        "Page \(number) of \(count)"
    }

    // MARK: - Lo que no cabe

    /// - Parameter what: lo que no se imprime, en plural y con mayúscula (`Connections`).
    /// - Parameter file: el documento del paquete donde está la lista entera.
    public static func reportOmitted(_ count: Int, of what: String, in file: String) -> String {
        "\(what) not printed here: \(count). The whole list is in \(file)."
    }
}
