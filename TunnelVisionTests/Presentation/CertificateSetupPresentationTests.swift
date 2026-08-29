import Foundation
import XCTest

/// Tests del núcleo puro del flujo guiado de la CA (M10).
///
/// Lo que se afirma aquí no es copia bonita: son las reglas de consentimiento del producto. **Dónde
/// está el usuario** sale del estado del sistema y no de un contador; **qué se le ofrece** nunca
/// incluye crear una CA encima de otra que quizá exista; y **qué se le promete** no incluye jamás saber
/// cuál de los dos pasos de los Ajustes de iOS le falta, porque iOS no lo dice.
final class CertificateSetupPresentationTests: XCTestCase {

    private let everyStatus: [CertificateStatus] = [
        CertificateStatus(authority: .notGenerated),
        CertificateStatus(authority: .generated(.trusted)),
        CertificateStatus(authority: .generated(.notTrusted)),
        CertificateStatus(authority: .generated(.cannotEvaluate("sin evaluar"))),
        CertificateStatus(authority: .unknown("llavero ilegible")),
    ]

    private var everyStage: [CertificateSetupStage] {
        [.explainTradeOff, .generate, .installAndTrust, .ready, .unavailable("motivo")]
    }

    // MARK: - La etapa

    /// La puerta del paso 0 está delante de **crear**, y solo ahí: sin CA y sin haber leído la
    /// explicación, no se ofrece crear nada.
    func testWithoutACATheFlowExplainsBeforeItOffersToCreate() {
        let status = CertificateStatus(authority: .notGenerated)

        XCTAssertEqual(CertificateSetupPolicy.stage(for: status, tradeOffAcknowledged: false), .explainTradeOff)
        XCTAssertEqual(CertificateSetupPolicy.stage(for: status, tradeOffAcknowledged: true), .generate)
    }

    /// Con una CA ya generada la explicación ya se leyó —no hay otra forma de haber llegado ahí—, así
    /// que exigirla otra vez sería insistir con algo ya decidido.
    func testAnExistingCAIsNotSentBackToTheExplanation() {
        for acknowledged in [true, false] {
            XCTAssertEqual(
                CertificateSetupPolicy.stage(
                    for: CertificateStatus(authority: .generated(.notTrusted)),
                    tradeOffAcknowledged: acknowledged
                ),
                .installAndTrust
            )
            XCTAssertEqual(
                CertificateSetupPolicy.stage(
                    for: CertificateStatus(authority: .generated(.trusted)),
                    tradeOffAcknowledged: acknowledged
                ),
                .ready
            )
        }
    }

    /// La duda cierra: una confianza que no se pudo evaluar **no** se lee como confianza, así que el
    /// flujo sigue enseñando lo que queda por hacer.
    func testTrustThatCouldNotBeEvaluatedIsNotTrust() {
        XCTAssertEqual(
            CertificateSetupPolicy.stage(
                for: CertificateStatus(authority: .generated(.cannotEvaluate("SecTrust"))),
                tradeOffAcknowledged: true
            ),
            .installAndTrust
        )
    }

    /// Y un llavero ilegible no es "no hay CA": es que no se sabe, y ahí no se ofrece nada que pueda
    /// reemplazar la CA que el usuario quizá ya instaló.
    func testAnUnreadableKeychainOffersNothingThatCouldReplaceACA() {
        let stage = CertificateSetupPolicy.stage(
            for: CertificateStatus(authority: .unknown("errSecInteractionNotAllowed")),
            tradeOffAcknowledged: true
        )

        XCTAssertEqual(stage, .unavailable("errSecInteractionNotAllowed"))
        let presentation = CertificateSetupPresentation.forStage(stage)
        XCTAssertEqual(presentation.primary.action, .retryStatus)
        XCTAssertNil(presentation.secondary)
        XCTAssertEqual(presentation.note?.text, "errSecInteractionNotAllowed", "el diagnóstico se enseña, no se esconde")
    }

    // MARK: - Lo que se ofrece

    func testDestructiveActionsAreOnlyOfferedOverACAThatIsKnownToExist() {
        for status in everyStatus {
            let expected: Bool
            switch status.authority {
            case .generated: expected = true
            case .notGenerated, .unknown: expected = false
            }
            XCTAssertEqual(CertificateSetupPolicy.canRegenerate(status), expected, "\(status)")
            XCTAssertEqual(CertificateSetupPolicy.canRemove(status), expected, "\(status)")
        }
    }

    /// Crear solo se ofrece desde su etapa. Sin esto, un botón de crear en otra pantalla del flujo
    /// podría reemplazar una raíz ya instalada sin pasar por la confirmación que nombra lo que se
    /// pierde.
    func testOnlyOneStageOffersToCreateACertificate() {
        let offering = everyStage.filter { stage in
            let presentation = CertificateSetupPresentation.forStage(stage)
            return presentation.primary.action == .generate || presentation.secondary?.action == .generate
        }

        XCTAssertEqual(offering, [.generate])
    }

    /// La regla de consentimiento del producto: siempre hay un camino para no hacerlo. La única etapa
    /// sin salida aparte es aquella cuya acción principal ya **es** salir.
    func testEveryStageOffersAWayOut() {
        for stage in everyStage {
            for enabled in [true, false] {
                let presentation = CertificateSetupPresentation.forStage(stage, inspectionEnabled: enabled)
                XCTAssertTrue(
                    presentation.dismiss != nil || presentation.primary.action == .finish,
                    "\(stage) no deja salir sin hacer nada"
                )
                XCTAssertFalse(presentation.title.isEmpty)
                XCTAssertFalse(presentation.message.isEmpty)
            }
        }
    }

    /// Y ninguna salida hace nada: salir es salir, no una acción disfrazada.
    func testTheWayOutDoesNothing() {
        for stage in everyStage {
            let presentation = CertificateSetupPresentation.forStage(stage)
            if let dismiss = presentation.dismiss {
                XCTAssertEqual(dismiss.action, .finish, "\(stage)")
            }
        }
    }

    // MARK: - El paso 0

    /// La explicación nombra el trato entero: lo que se gana y lo que **no** cambia. Una que solo
    /// prometiera ver dentro del tráfico dejaría al usuario esperando que los pinneados también se
    /// abrieran, y leyendo su negativa como una avería.
    func testTheTradeOffNamesWhatStaysPrivateAndThatNothingLeavesTheDevice() {
        let presentation = CertificateSetupPresentation.forStage(.explainTradeOff)
        let text = (presentation.message + " " + (presentation.note?.text ?? "")).lowercased()

        XCTAssertTrue(text.contains("pin"), "los pinneados se nombran antes de que el usuario los vea")
        XCTAssertTrue(text.contains("install"), "se dice que el certificado lo instala el usuario")
        XCTAssertTrue(text.contains("leaves this device") || text.contains("never leaves"), text)
        XCTAssertEqual(presentation.primary.action, .acknowledgeTradeOff, "leer no crea nada")
    }

    // MARK: - Los pasos 2 y 3

    /// La consecuencia del límite del sistema: los dos pasos se enseñan **juntos** y el flujo dice por
    /// qué, en vez de afirmar cuál falta. Decir "ya lo instalaste, solo falta confiar" a quien no lo
    /// instaló le deja sin salida.
    func testInstallAndTrustShowsBothStepsAndSaysWhy() {
        let presentation = CertificateSetupPresentation.forStage(.installAndTrust)
        let guidance = presentation.guidance
        let note = presentation.note?.text

        XCTAssertEqual(guidance, CertificateSetupPresentation.installSteps + CertificateSetupPresentation.trustSteps)
        XCTAssertTrue(guidance.contains { $0.detail.contains("VPN & Device Management") })
        XCTAssertTrue(guidance.contains { $0.detail.contains("Certificate Trust Settings") })
        XCTAssertTrue((note ?? "").lowercased().contains("doesn't let tunnelvision see"), note ?? "")
    }

    /// Comprobar es una acción aparte de instalar: son dos cosas distintas y el usuario vuelve de los
    /// Ajustes de iOS a la segunda, no a la primera.
    func testInstallAndTrustOffersBothInstallingAndChecking() {
        let presentation = CertificateSetupPresentation.forStage(.installAndTrust)

        XCTAssertEqual(presentation.primary.action, .shareProfile)
        XCTAssertEqual(presentation.secondary?.action, .recheckTrust)
    }

    /// El aviso de *No firmado* se nombra **antes** de que aparezca. Es la misma regla que la hoja del
    /// permiso de VPN, y aquí importa más: un aviso en rojo sobre un certificado es exactamente lo que
    /// enseña a la gente a no seguir adelante.
    func testTheUnsignedWarningIsNamedBeforeItAppears() {
        let steps = CertificateSetupPresentation.installSteps

        XCTAssertTrue(steps.contains { $0.detail.contains("Not Signed") }, "iOS lo va a decir; lo decimos primero")
    }

    /// Los pasos van numerados de corrido entre las dos mitades: el usuario los sigue saliendo y
    /// entrando de la app, y dos listas que empiezan por 1 se leen como dos recorridos.
    func testTheGuidedStepsAreNumberedInOneRun() {
        let steps = CertificateSetupPresentation.installSteps + CertificateSetupPresentation.trustSteps

        XCTAssertEqual(steps.map(\.number), Array(1...steps.count))
        XCTAssertTrue(steps.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
    }

    // MARK: - Dónde se lee la advertencia de una etapa

    /// La regla que separa las tres notas del flujo: **de qué son pie**. No se puede ser el pie de una
    /// lista de instrucciones que la etapa no tiene, y una etapa que sí la tiene no puede explicarla
    /// antes de enseñarla. Es la invariante que sostiene el sitio, y la que un `if let note` en la
    /// vista no podía tener: allí las tres se dibujaban igual.
    func testANoteIsOnlyTheFootOfGuidanceThatExists() {
        for stage in everyStage {
            let presentation = CertificateSetupPresentation.forStage(stage)
            guard let note = presentation.note else { continue }

            if note.placement == .footOfGuidance {
                XCTAssertFalse(
                    presentation.guidance.isEmpty,
                    "\(stage) pone su nota al pie de un recorrido que no tiene"
                )
            } else {
                XCTAssertTrue(
                    presentation.guidance.isEmpty,
                    "\(stage) tiene recorrido y lee su nota fuera de él"
                )
            }
        }
    }

    /// El paso 0 no tiene recorrido, así que sus tres promesas —nada se sube, la clave privada se
    /// queda, todo es reversible— son lo que la etapa afirma y se leen en la columna de la prosa. En
    /// una caja eran el texto más apagado de la pantalla que descansa sobre ellas.
    func testTheTradeOffPromisesAreReadInTheColumnOfTheProse() {
        let presentation = CertificateSetupPresentation.forStage(.explainTradeOff)

        XCTAssertEqual(presentation.note?.placement, .belowMessage)
        XCTAssertTrue(presentation.guidance.isEmpty)
    }

    /// La nota de la etapa de instalación explica **por qué siguen ahí los cinco pasos**, así que
    /// delante de ellos es la respuesta antes de la pregunta — y en medio empujaba la primera
    /// instrucción hasta el punto 462 de una ventana de 531.
    func testTheReasonBothStepsStayIsReadAtTheFootOfThem() {
        let presentation = CertificateSetupPresentation.forStage(.installAndTrust)

        XCTAssertEqual(presentation.note?.placement, .footOfGuidance)
        XCTAssertFalse(presentation.guidance.isEmpty)
    }

    /// El diagnóstico del llavero conserva su propia superficie, y es el único que la conserva: no es
    /// copia nuestra sino lo que contestó el sistema, y es además el único caso del flujo que sigue
    /// siendo una avería que ocurre **ahora**.
    func testOnlyTheSystemsOwnAnswerKeepsASurfaceOfItsOwn() {
        let ownSurface = everyStage.filter { stage in
            CertificateSetupPresentation.forStage(stage).note?.placement == .ownSurface
        }

        XCTAssertEqual(ownSurface, [.unavailable("motivo")])
        XCTAssertEqual(
            CertificateSetupPresentation.forStage(.unavailable("errSecInteractionNotAllowed")).note?.text,
            "errSecInteractionNotAllowed",
            "el diagnóstico se enseña tal cual: ni se traduce ni se maquilla"
        )
    }

    // MARK: - El paso 4

    /// Llegar con la inspección apagada ofrece encenderla; llegar con ella encendida no puede ofrecer
    /// encenderla otra vez.
    func testTheLastStageOffersToTurnItOnOnlyWhenItIsOff() {
        let off = CertificateSetupPresentation.forStage(.ready, inspectionEnabled: false)
        let on = CertificateSetupPresentation.forStage(.ready, inspectionEnabled: true)

        XCTAssertEqual(off.primary.action, .enableInspection)
        XCTAssertNotNil(off.dismiss, "encender es opcional, también aquí")
        XCTAssertEqual(on.primary.action, .finish)
    }

    /// Y las dos formas de terminar dicen lo mismo sobre lo que se ve y lo que sigue sin verse: el
    /// producto no puede prometer más de lo que hace justo cuando el usuario acaba de darle permiso.
    func testBothEndingsNameWhatStaysPrivate() {
        for enabled in [true, false] {
            let message = CertificateSetupPresentation.forStage(.ready, inspectionEnabled: enabled).message.lowercased()
            XCTAssertTrue(message.contains("pin"), message)
            XCTAssertTrue(message.contains("turn this off") || message.contains("any time"), message)
        }
    }

    // MARK: - Confirmaciones y avisos

    /// Las dos acciones destructivas nombran lo que se pierde antes de llevárselo, como los topes de
    /// retención.
    func testTheDestructiveConfirmationsNameWhatIsLost() {
        let regenerate = CertificateSetupPresentation.regenerate
        let remove = CertificateSetupPresentation.remove

        XCTAssertEqual(regenerate.kind, .regenerate)
        XCTAssertTrue(regenerate.message.lowercased().contains("stops working"), regenerate.message)
        XCTAssertTrue(regenerate.message.lowercased().contains("turned off"), regenerate.message)

        XCTAssertEqual(remove.kind, .remove)
        XCTAssertTrue(remove.message.lowercased().contains("deleted"), remove.message)
        XCTAssertTrue(remove.message.lowercased().contains("history"), "lo que **no** se toca también se dice")
        XCTAssertFalse(regenerate.confirmTitle.isEmpty)
        XCTAssertFalse(remove.confirmTitle.isEmpty)
    }

    /// Comprobar y que siga sin confiar **no es un fallo**, y su papel de color lo dice: llamarlo error
    /// empujaría a rehacer lo que ya se hizo bien.
    func testStillNotTrustedIsNotAFailure() {
        let notice = CertificateSetupPresentation.stillNotTrusted

        XCTAssertEqual(notice.role, .neutral)
        XCTAssertTrue(notice.message.contains("Certificate Trust Settings") || notice.message.contains("full trust"))
        XCTAssertNil(notice.diagnostic)
    }

    /// El caso que aborta: si la inspección no se pudo apagar, la CA se queda **exactamente** como
    /// estaba, y el aviso dice por qué en vez de dejarlo como un fallo sin causa.
    func testTheAbortNoticeExplainsWhyTheCAWasLeftAlone() {
        let notice = CertificateSetupPresentation.inspectionCouldNotBeTurnedOff("write failed")

        XCTAssertEqual(notice.role, .warning)
        XCTAssertTrue(notice.message.lowercased().contains("left exactly as it was"), notice.message)
        XCTAssertEqual(notice.diagnostic, "write failed")
    }

    /// Quitar la clave es solo la mitad: la otra la hace el usuario en los Ajustes de iOS, y se le
    /// enseña **después** de borrarla, porque hasta entonces no hay nada que retirar.
    func testRemovalGuidanceNamesTheProfileAndOnlyExistsAfterTheKeyIsGone() {
        let steps = CertificateSetupPresentation.removalSteps

        XCTAssertEqual(steps.map(\.number), [1])
        XCTAssertTrue(steps[0].detail.contains("VPN & Device Management"))
        XCTAssertTrue(steps[0].detail.lowercased().contains("already gone"), steps[0].detail)
    }

    // MARK: - La entrega del perfil

    /// La hoja que precede a la del sistema dice las tres cosas que la hoja de compartir no dice: qué
    /// hacer con el fichero, que *Profile Downloaded* **no** es "instalado" —creerlo dejaría al usuario
    /// esperando a que pase algo que ya pasó, sin hacer el paso que falta— y qué no hacer con él.
    func testTheProfileHandoffExplainsWhatToDoAndWhatNotToDo() {
        let handoff = CertificateSetupPresentation.profileHandoff

        XCTAssertTrue(handoff.message.contains("Save to Files"), handoff.message)
        XCTAssertTrue(handoff.message.contains("not installed"), handoff.message)
        XCTAssertFalse(handoff.shareTitle.isEmpty)
        XCTAssertFalse(handoff.title.isEmpty)
    }

    /// Es el único momento del flujo en que un fichero nuestro puede salir del dispositivo, así que se
    /// dice **antes** de que aparezca la hoja del sistema —la misma regla que el permiso de VPN— y se
    /// dice qué es lo que se está moviendo: el certificado, nunca la clave que firma con él.
    func testTheHandoffWarnsAgainstMovingTheFileAndSaysWhy() {
        let warning = CertificateSetupPresentation.profileHandoff.warning.lowercased()

        XCTAssertTrue(warning.contains("keep this file on this device"), warning)
        XCTAssertTrue(warning.contains("never its private key"), warning)
        // El motivo, y no solo la prohibición: una advertencia sin causa se salta.
        XCTAssertTrue(warning.contains("trusting"), warning)
    }

    // MARK: - Rehacer y quitar

    /// Desde fuera las dos acciones se leen igual ("empezar de cero"), así que el pie dice en qué se
    /// diferencian y, sobre todo, qué **no** se lleva ninguna de las dos.
    func testTheManageFooterSaysWhatNeitherActionTouches() {
        let footer = CertificateSetupPresentation.manageFooter.lowercased()

        XCTAssertTrue(footer.contains("replaces"), footer)
        XCTAssertTrue(footer.contains("deletes"), footer)
        XCTAssertTrue(footer.contains("history"), footer)
        XCTAssertTrue(footer.contains("captures"), footer)
    }

    /// El encabezado de la retirada sitúa al usuario: lo que ya pasó lo cuenta el aviso, y esto es lo
    /// que le queda por hacer, que además es fuera de la app.
    func testTheRemovalGuidanceIsHeadedAsWhatIsLeftToDo() {
        let title = CertificateSetupPresentation.removalGuidanceTitle

        XCTAssertTrue(title.contains("iOS Settings"), title)
        XCTAssertNotEqual(title, CertificateSetupPresentation.certificateRemoved.message)
    }

    /// Ninguna copia del flujo insinúa que algo salga del dispositivo, que es la promesa que el
    /// producto entero sostiene y la que más caro costaría romper justo aquí — donde el usuario está
    /// entregándole a la app la llave de su propio tráfico cifrado.
    func testNoCopyClaimsAnythingLeavesTheDevice() {
        var text = ""
        for stage in everyStage {
            for enabled in [true, false] {
                let presentation = CertificateSetupPresentation.forStage(stage, inspectionEnabled: enabled)
                text += presentation.message + " " + (presentation.note?.text ?? "") + " "
                text += presentation.guidance.map { $0.detail }.joined(separator: " ")
            }
        }
        // La entrega entra en el mismo listón, y es la que más cerca está de la excepción: aquí sí hay
        // un fichero que se puede mover, y lo que se dice de él es que no se mueva.
        let handoff = CertificateSetupPresentation.profileHandoff
        text += handoff.message + " " + handoff.warning
        let lowered = text.lowercased()

        XCTAssertFalse(lowered.contains("our server"), text)
        XCTAssertFalse(lowered.contains("cloud"), text)
        XCTAssertFalse(lowered.contains("sent to us"), text)
        XCTAssertTrue(lowered.contains("nothing is uploaded"), "y se dice de frente, no por omisión")
    }

    // MARK: - La copia por el catálogo (M11)

    /// Toda la copia de esta mitad del flujo, con el sitio del que sale, para poder afirmar sobre ella
    /// en bloque. El diagnóstico del llavero **no entra**: es del sistema, no copia nuestra, y por eso
    /// la etapa `unavailable` se pide aquí sin él.
    private var everyPieceOfCopy: [(where: String, text: String)] {
        var copy: [(where: String, text: String)] = []

        for stage in [.explainTradeOff, .generate, .installAndTrust, .ready, .unavailable("")] as [CertificateSetupStage] {
            for enabled in [true, false] {
                let presentation = CertificateSetupPresentation.forStage(stage, inspectionEnabled: enabled)
                copy.append(("\(stage).title", presentation.title))
                copy.append(("\(stage).message", presentation.message))
                copy.append(("\(stage).primary", presentation.primary.title))
                if let secondary = presentation.secondary { copy.append(("\(stage).secondary", secondary.title)) }
                if let dismiss = presentation.dismiss { copy.append(("\(stage).dismiss", dismiss.title)) }
                if case .unavailable = stage {} else if let note = presentation.note {
                    copy.append(("\(stage).note", note.text))
                }
            }
        }

        for (name, notice) in everyNotice {
            copy.append(("notice.\(name)", notice.message))
        }

        for confirmation in [CertificateSetupPresentation.regenerate, CertificateSetupPresentation.remove] {
            copy.append(("confirm.\(confirmation.kind).title", confirmation.title))
            copy.append(("confirm.\(confirmation.kind).message", confirmation.message))
            copy.append(("confirm.\(confirmation.kind).confirm", confirmation.confirmTitle))
        }

        copy.append(("manage.regenerate", CertificateSetupPresentation.regenerateActionTitle))
        copy.append(("manage.remove", CertificateSetupPresentation.removeActionTitle))
        copy.append(("manage.footer", CertificateSetupPresentation.manageFooter))

        for step in everyStep {
            copy.append(("step.\(step.number).title", step.title))
            copy.append(("step.\(step.number).detail", step.detail))
            copy.append(("step.\(step.number).accessibilityLabel", step.accessibilityLabel))
        }
        copy.append(("guidance.removal.title", CertificateSetupPresentation.removalGuidanceTitle))

        let handoff = CertificateSetupPresentation.profileHandoff
        copy.append(("handoff.title", handoff.title))
        copy.append(("handoff.message", handoff.message))
        copy.append(("handoff.warning", handoff.warning))
        copy.append(("handoff.share", handoff.shareTitle))

        copy.append(("screen.title", CertificateSetupPresentation.screenTitle))

        return copy
    }

    /// Los seis pasos numerados que existen: los cinco del recorrido de ida y el único de la retirada.
    private var everyStep: [CertificateSetupStep] {
        CertificateSetupPresentation.installSteps
            + CertificateSetupPresentation.trustSteps
            + CertificateSetupPresentation.removalSteps
    }

    /// Los doce avisos, con su nombre. Los que llevan diagnóstico se piden con uno cualquiera: lo que
    /// se afirma aquí es su mensaje, que es la parte que sí es copia.
    private var everyNotice: [(String, CertificateSetupNotice)] {
        [
            ("certificateCreated", CertificateSetupPresentation.certificateCreated),
            ("generationFailed", CertificateSetupPresentation.generationFailed("d")),
            ("profileUnavailable", CertificateSetupPresentation.profileUnavailable("d")),
            ("certificateMissing", CertificateSetupPresentation.certificateMissing),
            ("stillNotTrusted", CertificateSetupPresentation.stillNotTrusted),
            ("nowTrusted", CertificateSetupPresentation.nowTrusted),
            ("inspectionTurnedOn", CertificateSetupPresentation.inspectionTurnedOn),
            ("inspectionOnButNotLive", CertificateSetupPresentation.inspectionOnButNotLive("d")),
            ("certificateRemoved", CertificateSetupPresentation.certificateRemoved),
            ("removalFailed", CertificateSetupPresentation.removalFailed("d")),
            ("inspectionCouldNotBeTurnedOff", CertificateSetupPresentation.inspectionCouldNotBeTurnedOff("d")),
            ("inspectionCouldNotBeTurnedOn", CertificateSetupPresentation.inspectionCouldNotBeTurnedOn("d")),
        ]
    }

    /// El fallo característico de una migración al catálogo: una llamada sin `defaultValue` devuelve
    /// **la clave**, y una clave estructural se lee perfectamente en un diff sin llamar la atención.
    /// Aquí saldría a la pantalla de un flujo cuya copia es lo único que sostiene el consentimiento.
    func testNoCopyIsARawCatalogKey() {
        for piece in everyPieceOfCopy {
            XCTAssertFalse(piece.text.hasPrefix("certificateSetup."), "\(piece.where): \(piece.text)")
            XCTAssertFalse(piece.text.isEmpty, "\(piece.where) se quedó sin copia")
        }
    }

    /// El otro fallo característico, y el que ningún test de contenido ve: al mudar un literal
    /// multilínea cambia dónde caen las continuaciones (`\`), y una mal puesta mete un espacio doble o
    /// deja un sobrante en un extremo. El texto sigue diciendo lo mismo y se ve mal.
    func testNoCopyCarriesStrayWhitespace() {
        for piece in everyPieceOfCopy {
            XCTAssertFalse(piece.text.contains("  "), "\(piece.where): espacio doble en «\(piece.text)»")
            XCTAssertEqual(
                piece.text.trimmingCharacters(in: .whitespacesAndNewlines),
                piece.text,
                "\(piece.where): sobra espacio en un extremo"
            )
            for line in piece.text.split(separator: "\n") {
                XCTAssertFalse(line.hasSuffix(" "), "\(piece.where): una línea acaba en espacio")
            }
        }
    }

    /// La explicación del paso 0 son **dos párrafos** y el segundo es el de los pinneados. Una
    /// continuación de línea mal puesta los fundiría en uno, que es la forma más fácil de que la mitad
    /// que protege a las otras apps se lea como una coletilla de la que promete ver dentro.
    func testTheTradeOffKeepsItsTwoParagraphs() {
        let message = CertificateSetupPresentation.forStage(.explainTradeOff).message
        let paragraphs = message.components(separatedBy: "\n\n")

        XCTAssertEqual(paragraphs.count, 2, message)
        XCTAssertTrue(paragraphs[1].lowercased().contains("pin"), paragraphs[1])
    }

    /// Las tres etapas en las que todavía no se ha hecho nada irreversible salen por la misma puerta y
    /// con las mismas palabras: es una sola clave, y tres traducciones distintas de la misma idea solo
    /// podrían separarse. Las otras dos salidas sí dicen algo distinto, porque lo son.
    func testTheWaysOutAreSharedWhereTheyMeanTheSameAndSeparateWhereTheyDoNot() {
        let notYet = [CertificateSetupStage.explainTradeOff, .generate, .ready].map {
            CertificateSetupPresentation.forStage($0).dismiss?.title
        }
        let started = CertificateSetupPresentation.forStage(.installAndTrust).dismiss?.title
        let unavailable = CertificateSetupPresentation.forStage(.unavailable("d")).dismiss?.title

        XCTAssertEqual(Set(notYet.compactMap { $0 }).count, 1, "\(notYet)")
        XCTAssertNotEqual(started, notYet.first ?? nil, "sobre algo ya empezado no se dice 'todavía no'")
        XCTAssertNotEqual(unavailable, notYet.first ?? nil, "donde no hay nada que posponer, tampoco")
        XCTAssertNotEqual(started, unavailable)
    }

    /// Dos botones que dicen lo mismo y hacen cosas distintas son el peor resultado posible de repartir
    /// la copia en claves: aquí la única palabra que se repite es la de salir, y salir es una sola cosa
    /// aunque se diga de cuatro maneras según lo que quede detrás.
    func testTwoDifferentActionsNeverShareTheSameWords() {
        var buttons: [CertificateSetupButton] = []
        for stage in everyStage {
            for enabled in [true, false] {
                let presentation = CertificateSetupPresentation.forStage(stage, inspectionEnabled: enabled)
                for button in [presentation.primary, presentation.secondary, presentation.dismiss].compactMap({ $0 }) {
                    XCTAssertFalse(button.title.isEmpty, "\(stage): un botón sin rótulo")
                    buttons.append(button)
                }
            }
        }

        for (index, one) in buttons.enumerated() {
            for other in buttons[(index + 1)...] {
                guard one.action != other.action else {
                    // Salir es la excepción: se dice de cuatro maneras según lo que quede detrás.
                    if one.action != .finish {
                        XCTAssertEqual(one.title, other.title, "\(one.action) se dice de dos maneras")
                    }
                    continue
                }
                XCTAssertNotEqual(
                    one.title,
                    other.title,
                    "«\(one.title)» rotula dos acciones distintas: \(one.action) y \(other.action)"
                )
            }
        }
    }

    /// Los doce avisos cuentan doce cosas distintas, y el único sitio donde el usuario se entera de qué
    /// acaba de pasar es ese mensaje: dos que se leyeran igual harían indistinguibles, por ejemplo, un
    /// certificado que no se pudo crear de uno que no se pudo quitar.
    func testEveryNoticeSaysSomethingOfItsOwn() {
        let messages = everyNotice.map(\.1.message)

        XCTAssertEqual(Set(messages).count, messages.count, "hay dos avisos que dicen lo mismo")
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
    }

    /// Lo que se ve y lo que sigue sin verse es **una sola clave** dicha en los dos finales: dos copias
    /// de la misma promesa acabarían discrepando, y la que se rompería es la que nombra lo que el
    /// producto no puede hacer.
    func testBothEndingsExplainWhatDoesNotChangeWithTheSameWords() {
        let off = CertificateSetupPresentation.forStage(.ready, inspectionEnabled: false)
        let on = CertificateSetupPresentation.forStage(.ready, inspectionEnabled: true)

        XCTAssertEqual(off.message, on.message)
        XCTAssertNotEqual(off.title, on.title, "el estado sí cambia, y el titular es lo que lo dice")
    }

    /// Los dos pasos que mandan tocar un botón **leen el rótulo de ese botón**, no una copia suya. Es
    /// el fallo que una traducción no deja ver: la frase sigue leyéndose perfectamente y manda buscar
    /// algo que en la pantalla se llama de otra manera, justo en el punto del flujo en que el usuario
    /// está siguiendo instrucciones al pie de la letra porque no sabe qué está haciendo.
    func testTheStepsThatNameAButtonUseThatButtonsOwnWords() {
        let presentation = CertificateSetupPresentation.forStage(.installAndTrust)
        let install = presentation.primary.title
        let recheck = try? XCTUnwrap(presentation.secondary?.title)

        let first = CertificateSetupPresentation.installSteps[0].detail
        let last = CertificateSetupPresentation.trustSteps.last?.detail ?? ""

        XCTAssertTrue(first.contains(install), "«\(first)» no nombra el botón «\(install)»")
        XCTAssertTrue(last.contains(recheck ?? ""), "«\(last)» no nombra el botón «\(recheck ?? "")»")
    }

    /// Lo que se oye de un paso lo compone el paso, no la vista: el orden y el separador son propiedad
    /// de un idioma, y una frase montada dentro de SwiftUI no tiene dónde cambiarlos. Lleva el número
    /// aunque el círculo esté oculto para VoiceOver — quien escucha no ve por dónde va un recorrido que
    /// se hace saliendo de la app entre paso y paso.
    func testEveryStepReadsAsOneSentenceWithItsNumber() {
        for step in everyStep {
            let label = step.accessibilityLabel

            XCTAssertTrue(label.contains("\(step.number)"), "\(step.number): sin número en «\(label)»")
            XCTAssertTrue(label.contains(step.title), "\(step.number): sin título en «\(label)»")
            XCTAssertTrue(label.contains(step.detail), "\(step.number): sin instrucción en «\(label)»")
        }
    }

    /// El recorrido pasa por los Ajustes de iOS y por sus nombres, no por los nuestros: un paso que
    /// tradujera *Files* o *Not Signed* de oído mandaría al usuario a buscar algo que no existe. Aquí se
    /// afirma que esas palabras siguen estando; que sean las del sistema en cada idioma es lo que dice
    /// el comentario de cada clave.
    func testTheGuidedStepsStillNameWhatIOSCallsThings() {
        let outbound = (CertificateSetupPresentation.installSteps + CertificateSetupPresentation.trustSteps)
            .map(\.detail)
            .joined(separator: " ")

        for name in ["Save to Files", "Files", "Profile Downloaded", "Not Signed", "Certificate Trust Settings"] {
            XCTAssertTrue(outbound.contains(name), "falta «\(name)»")
        }
        XCTAssertTrue(CertificateSetupPresentation.removalSteps[0].detail.contains("Remove Profile"))
    }

    /// El título de la pantalla es **su propia clave** aunque hoy diga lo mismo que la fila de Ajustes
    /// que lleva a ella: son dos sitios distintos y un idioma puede necesitar acortar uno sin tocar el
    /// otro. Lo que sí tiene que seguir siendo es corto: vive en una barra de navegación.
    func testTheScreenTitleIsItsOwnCopyAndStaysShort() {
        let title = CertificateSetupPresentation.screenTitle
        let row = CertificateSetupPresentation.forStage(.explainTradeOff).title

        XCTAssertFalse(title.isEmpty)
        XCTAssertNotEqual(title, row, "el titular del paso 0 dice más que el título de la pantalla")
        XCTAssertLessThan(title.count, 30, title)
    }

    /// La fila **pide** y el botón de la confirmación **hace**, así que no pueden decir lo mismo: leer
    /// dos veces el mismo rótulo haría creer que el primer toque ya se llevó el certificado.
    func testAskingForADestructiveActionAndCarryingItOutAreWordedApart() {
        let regenerate = CertificateSetupPresentation.regenerate
        let remove = CertificateSetupPresentation.remove

        XCTAssertNotEqual(CertificateSetupPresentation.regenerateActionTitle, regenerate.confirmTitle)
        XCTAssertNotEqual(CertificateSetupPresentation.removeActionTitle, remove.confirmTitle)
        XCTAssertNotEqual(regenerate.confirmTitle, remove.confirmTitle, "las dos acciones no se aceptan igual")
        XCTAssertNotEqual(regenerate.title, remove.title)
    }
}
