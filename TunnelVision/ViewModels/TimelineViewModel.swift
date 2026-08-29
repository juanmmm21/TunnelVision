import CoreGraphics
import Foundation
import Observation
import Shared

/// El view model de la Timeline (M9): la capa entre el `HistoryReader` —un **actor**— y SwiftUI.
///
/// Hace tres cosas: consume el stream de instantáneas y las publica en el `MainActor`, traduce las
/// opciones de la pantalla a un `HistoryFilter`, y **abre el historial en diferido**. Lo demás
/// (paginación, cursor, filtrado, orden) ya está resuelto en el servicio.
///
/// Abrir en diferido no es un detalle de arranque: el `FlowStore` vive en el contenedor del App Group
/// y abrirlo **puede fallar** (falta el entitlement, la BD no se puede leer). Si la app lo construyese
/// en el arranque, un fallo ahí se llevaría por delante toda la app —incluida la Dashboard, que no
/// necesita la BD para nada—. Abriéndolo aquí, el fallo se convierte en un estado de la pantalla con
/// salida: "Try again" vuelve a intentar la apertura **de verdad**, que es lo que hace que el error no
/// sea un callejón sin salida (principio 7 de `docs/ux/00-ux-principles.md`).
///
/// Es `@MainActor` y `@Observable` como `DashboardViewModel` y `TunnelController`.
@MainActor
@Observable
public final class TimelineViewModel {

    // MARK: - Lo que pinta la vista

    /// La última instantánea publicada por el lector, o el fallo de la apertura si no llegó a haber
    /// lector.
    public private(set) var snapshot: HistorySnapshot = HistorySnapshot()

    /// Las filas de la lista con su copia ya compuesta, que es lo que la vista pinta.
    ///
    /// Se rehacen aquí y no en la fila porque componer cinco cadenas —cuatro de ellas con una
    /// búsqueda en el catálogo— dentro de un `body` es trabajo por fotograma de scroll, y este es el
    /// único sitio que sabe **cuándo** cambia la lista. Se rehacen enteras y solo cuando los flujos
    /// cambian: la copia no depende de nada más que de ellos, así que comparar los flujos es
    /// exactamente la condición que hace imposible que una fila pintada se quede con la copia de un
    /// flujo ya recargado — y de paso no rehace nada en las instantáneas que solo mueven el estado
    /// (una página en camino, un fallo con la lista ya puesta).
    public private(set) var rows: [TimelineRow] = []

    /// El texto de la barra de búsqueda. Es `var` porque lo escribe la vista, y **no dispara nada por
    /// sí solo**: la búsqueda se aplica al enviarla (`submitSearch()`).
    ///
    /// Buscar en cada tecla sería lo natural si el filtro fuese una consulta indexada, pero no lo es:
    /// el texto se busca contra el host visible, así que el lector encadena páginas del store y las
    /// descarta en memoria (`docs/spec/app-services.md`). Reejecutar ese barrido por cada letra
    /// tecleada gasta lecturas de disco para enseñar listas que el usuario no llega a mirar.
    public var searchText: String = ""

    /// Lo que acota el tiempo: un preset del menú (relativo, se recalcula) o un tramo tocado en la
    /// barra de scrub (absoluto, no se recalcula nunca).
    public private(set) var dateFilter: TimelineDateFilter = .anyTime

    public private(set) var protocolSelection: Set<TimelineProtocolFilter> = []
    public private(set) var tlsSelection: Set<TLSInspectionStatus> = []

    /// El eje temporal del historial. Vacío mientras no se haya podido consultar.
    ///
    /// Va aparte de `snapshot` porque es otra consulta y tiene otro ciclo: la lista se rehace al
    /// cambiar un filtro y el eje **no**, porque no depende de ninguno. Lo que sí lo mueve es
    /// acercarse a un tramo, que es volver a pedirlo acotado.
    public private(set) var axis: ActivityAxis = .empty

    /// Por qué no se pudo leer el eje la última vez. Solo se enseña si además no hay eje dibujado.
    public private(set) var axisError: HistoryError?

    /// Por qué tramos ha bajado el eje. Vacía mientras abarque todo el historial.
    public private(set) var zoom: ScrubZoom = .wholeHistory

    /// Si queda algún tramo del eje en el que se pueda entrar. Es lo que impide prometer un gesto que
    /// en este eje ya no hace nada, y por eso lo lee `scrubAxis` y no la vista.
    public private(set) var canZoomFurther = false

    /// Lo que la barra dice de sí misma: el aviso y lo que VoiceOver oye del eje.
    ///
    /// Se compone al publicar un eje —que es cuando puede cambiar— y no en el `body` de la barra, que
    /// se reevalúa con cada fotograma de un arrastre. El valor de arranque no es un relleno: un eje
    /// vacío tiene su propia frase (`No recorded activity yet`), y es la verdad sobre el estado en el
    /// que la pantalla nace.
    public private(set) var scrubAxis = ScrubPresentation.forAxis(
        .empty, zoomed: false, zoomable: false
    )

    /// Lo que hay que contarle al usuario sobre la barra en este momento, si es que hay algo. Hoy solo
    /// tiene un caso: la retención se llevó el tramo al que se había bajado y el eje ha vuelto solo a
    /// todo el historial. Un salto así sin explicación se lee como un fallo.
    public private(set) var scrubNotice: String?

    // MARK: - Dependencias

    private let makeReader: @Sendable () async throws -> HistoryReader
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    /// El lector, una vez abierto. `nil` mientras no se haya conseguido abrir el historial.
    @ObservationIgnored private var reader: HistoryReader?

    /// La apertura en curso, memoizada para que dos llamadas simultáneas (la suscripción y la primera
    /// carga, que la vista lanza juntas) no abran dos veces la misma base de datos.
    @ObservationIgnored private var openTask: Task<HistoryReader, any Error>?

    @ObservationIgnored private var readerTask: Task<Void, Never>?

    /// El filtro que el lector tiene puesto ahora mismo. Empieza en `.none` porque es con el que
    /// arranca el lector: sin esto, la primera carga se saltaría (`apply` no hace nada si el filtro no
    /// cambia) y la pantalla se quedaría en blanco esperando algo que nadie pidió.
    @ObservationIgnored private var appliedFilter: HistoryFilter = .none

    /// Los tramos que el eje puede ofrecer con lo que mide la pantalla. `nil` mientras nadie la haya
    /// medido, que es lo que distingue "todavía no se sabe" de "caben pocos".
    @ObservationIgnored private var axisCapacity: Int?

    /// Qué carga del eje es la vigente. La aparición de la pantalla y su primera medida llegan casi a
    /// la vez y las dos piden el eje, así que sin esto la que se pidió **antes** puede contestar
    /// después y dejar dibujada la resolución que ya no toca.
    @ObservationIgnored private var axisGeneration = 0

    public init(
        makeReader: @escaping @Sendable () async throws -> HistoryReader,
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current
    ) {
        self.makeReader = makeReader
        self.now = now
        self.calendar = calendar
    }

    deinit {
        readerTask?.cancel()
        openTask?.cancel()
    }

    // MARK: - Suscripción

    /// Empieza a recibir instantáneas. Idempotente: la vista la llama en cada aparición.
    ///
    /// Si el historial no se puede abrir, deja la pantalla en `failed` y **no** se suscribe, así que
    /// el siguiente intento vuelve a probar la apertura en vez de quedarse esperando a un lector que
    /// no existe.
    public func startObserving() async {
        guard readerTask == nil, let reader = await resolvedReader() else { return }
        observe(reader)
    }

    /// Deja de recibirlas. **No** cierra el historial: la BD sigue abierta y la lista, cargada, para
    /// que volver a la pestaña no cueste una recarga entera.
    public func stopObserving() {
        readerTask?.cancel()
        readerTask = nil
    }

    // MARK: - Carga

    /// Recarga desde la primera página. La dispara la aparición de la pantalla y el tirar para
    /// refrescar: SQLite no notifica entre procesos y quien escribe es la extensión, así que el
    /// historial solo se actualiza cuando alguien lo pide (`docs/spec/app-services.md`).
    public func refresh() async {
        guard let reader = await resolvedReader() else { return }
        let filter = currentFilter()
        // Un rango relativo ("última hora") se recalcula en cada recarga, así que el filtro cambia
        // aunque el usuario no haya tocado nada; en ese caso recargar es aplicar el nuevo. Un tramo
        // elegido en la barra no cambia nunca por sí solo, que es justo para lo que existe.
        if filter != appliedFilter {
            appliedFilter = filter
            await reader.apply(filter)
        } else {
            await reader.refresh()
        }
        await loadActivity(from: reader)
    }

    /// Vuelve a pedir el eje temporal, acotado al tramo al que se haya bajado. Se hace en cada recarga
    /// y **no** al cambiar un filtro: el eje no lo mueve ningún filtro; lo que sí lo mueve es que la
    /// extensión haya escrito más tráfico, que la retención se haya llevado el más antiguo, o que el
    /// usuario se haya acercado.
    ///
    /// Un eje acercado que vuelve **a cero** solo puede significar que el tramo ya no está guardado:
    /// no se entra en tramos vacíos (`HistoryReader.canZoom`), así que el que estaba lleno al bajar y
    /// sale vacío al recargar se lo llevó la retención. Ahí se sube del todo —no un nivel, porque el
    /// nivel de encima puede haber caducado igual y comprobarlo uno a uno sería una consulta por
    /// nivel— y se dice, que es lo que separa una salida de un salto inexplicado.
    private func loadActivity(from reader: HistoryReader) async {
        axisGeneration += 1
        let generation = axisGeneration
        // Cuántos tramos caben lo sabe la pantalla y se aplica **antes de cada consulta**, no una vez
        // al medir: así una recarga que se cruce con la primera medida no puede pedir el eje con la
        // resolución de fábrica.
        if let axisCapacity { await reader.setAxisCapacity(axisCapacity) }
        do {
            let requested = zoom.current
            let loaded = try await reader.activity(in: requested)
            guard generation == axisGeneration else { return }
            axisError = nil

            guard requested != nil, loaded.totalPackets == 0 else {
                await publish(loaded, from: reader)
                scrubNotice = nil
                return
            }

            zoom.reset()
            let whole = try await reader.activity()
            guard generation == axisGeneration else { return }
            await publish(whole, from: reader)
            scrubNotice = ScrubPresentation.expiredZoomNotice
            // El tramo caducado tampoco puede seguir acotando la lista: dejarlo puesto daría un "no
            // matches" sobre un trozo del pasado que ya no existe, y el aviso habla del eje.
            if dateFilter.interval != nil {
                dateFilter = .anyTime
                await applyFilter()
            }
        } catch {
            guard generation == axisGeneration else { return }
            // El eje que falla **no** se lleva la lista consigo: es un adorno sobre una pantalla que
            // funciona, y llevarla a `failed` por él escondería las conexiones que sí se leyeron. El
            // fallo se queda aquí y solo se enseña si tampoco hay eje anterior que dibujar.
            axisError = HistoryError.classifying(error)
        }
    }

    /// Lo que mide la pantalla, que es lo que decide **cuántos tramos** puede ofrecer el eje: cada uno
    /// se toca con el dedo y le debe los 44 puntos de la HIG (`ScrubCapacity`). Lo dice la vista
    /// porque es la única que lo sabe; cuántos salen de ahí no lo decide ella.
    ///
    /// Una anchura que no dice nada todavía —una pantalla sin medir— no cambia nada, y una que da el
    /// mismo número tampoco: sin esa guarda, cada layout costaría una consulta de agregado al store.
    /// Cuando sí cambia, el eje se vuelve a pedir, porque su resolución es justo lo que cambió.
    public func setScreenWidth(_ width: CGFloat) async {
        guard let capacity = ScrubCapacity.intervals(inScreenOfWidth: width),
              capacity != axisCapacity
        else {
            return
        }
        axisCapacity = capacity
        guard let reader = await resolvedReader() else { return }
        await loadActivity(from: reader)
    }

    /// Trae la página siguiente hacia atrás en el tiempo. La dispara la lista al llegar al final.
    public func loadMore() async {
        guard let reader else { return }
        await reader.loadMore()
    }

    // MARK: - Filtros

    public func submitSearch() async {
        await applyFilter()
    }

    /// Elige un preset del menú. Suelta también el acercamiento: un preset es una regla sobre *ahora*
    /// y el eje acercado es un trozo concreto del pasado, así que dejar el eje dentro de un tramo
    /// mientras la lista obedece a otra cosa daría una barra que no explica lo que se está viendo.
    public func setTimeRange(_ range: TimelineTimeRange) async {
        dateFilter = .preset(range)
        await applyFilter()
        await reloadUnzoomedAxis()
    }

    /// Lo que hace el toque sobre un tramo de la barra: acotar la lista a él y, si dentro hay algo que
    /// mirar, **bajar el eje** a ese tramo.
    ///
    /// Filtrar y acercarse son el mismo gesto a propósito. Separarlos dejaría dos cosas puestas a la
    /// vez —lo que la lista enseña y lo que el eje abarca— que habría que explicar por separado, y en
    /// cuanto discrepasen la barra dejaría de decir qué se está viendo. Siendo lo mismo, hay una sola
    /// respuesta a "¿dónde estoy?", y la salida es el camino de vuelta (`ScrubZoom`).
    ///
    /// El intervalo se guarda **absoluto**: es un trozo concreto del pasado y no una regla como
    /// "última hora", así que ninguna recarga posterior lo recalcula. Volver a tocar lo que ya estaba
    /// puesto lo suelta, que es la salida más corta y la que el gesto sugiere: si se había bajado a
    /// él, soltarlo es subir un nivel.
    public func selectInterval(_ bar: ActivityBar) async {
        guard let reader = await resolvedReader() else { return }
        scrubNotice = nil

        if dateFilter.interval == bar.range {
            if zoom.current == bar.range {
                await zoomOut()
            } else {
                await clearInterval()
            }
            return
        }

        dateFilter = .interval(bar.range)
        await applyFilter()

        if await reader.canZoom(into: bar) {
            zoom.zoom(into: bar.range)
            await loadActivity(from: reader)
        }
    }

    /// Lo que hace el arrastre sobre varias barras: acotar la lista al tramo barrido, **sin bajar el
    /// eje**. El tramo llega ya redondeado a barras enteras (`ActivityAxis.sweep(from:to:)`).
    ///
    /// Que no baje el eje es la diferencia con el toque, y es deliberado: un tramo barrido no es una
    /// barra, así que entrar en él apilaría un nivel que no se corresponde con nada de lo dibujado —y
    /// "atrás" volvería entonces a un sitio que el usuario no eligió—. Tocar es elegir **dónde** mira
    /// el eje; barrer es elegir **cuánto** mira la lista, que es justo lo que el toque no sabe hacer
    /// en cuanto la resolución es fina (acotar una hora con barras de 15 minutos).
    ///
    /// Barrer otra vez lo mismo **no lo suelta**, al revés que volver a tocar el tramo que ya estaba
    /// puesto: repetir un rango exacto con el dedo no se hace sin querer, así que leerlo como "quitar
    /// el filtro" desharía el gesto que se acaba de hacer. La salida es el botón del pie.
    public func selectRange(_ range: ClosedRange<Date>) async {
        guard dateFilter.interval != range else { return }
        scrubNotice = nil
        dateFilter = .interval(range)
        await applyFilter()
    }

    /// Sube un nivel del acercamiento y deja la lista acotada a lo que el eje pasa a enseñar, que es
    /// el mismo trato que al bajar: lo dibujado y lo listado son lo mismo.
    public func zoomOut() async {
        guard zoom.isZoomed, let reader = await resolvedReader() else { return }
        scrubNotice = nil
        let parent = zoom.zoomOut()
        dateFilter = parent.map(TimelineDateFilter.interval) ?? .anyTime
        await applyFilter()
        await loadActivity(from: reader)
    }

    /// Vuelve de una vez a todo el historial. Solo se ofrece cuando desapilar de uno en uno no basta
    /// (`ScrubZoom.offersFullReset`): con un nivel puesto, "atrás" ya lleva aquí.
    public func showWholeHistory() async {
        guard zoom.isZoomed, let reader = await resolvedReader() else { return }
        scrubNotice = nil
        zoom.reset()
        dateFilter = .anyTime
        await applyFilter()
        await loadActivity(from: reader)
    }

    /// Suelta el tramo elegido y deja la lista acotada a lo que el eje está enseñando —todo el
    /// historial si no se ha bajado a ningún sitio—. **No sube el eje**: es la salida del tramo que no
    /// se pudo abrir, no la del acercamiento, que tiene la suya.
    ///
    /// No toca el resto de filtros: el usuario ha soltado el trozo del eje, no la búsqueda que tenía
    /// puesta.
    public func clearInterval() async {
        guard let interval = dateFilter.interval, interval != zoom.current else { return }
        dateFilter = zoom.current.map(TimelineDateFilter.interval) ?? .anyTime
        await applyFilter()
    }

    public func toggleProtocol(_ option: TimelineProtocolFilter) async {
        if protocolSelection.contains(option) {
            protocolSelection.remove(option)
        } else {
            protocolSelection.insert(option)
        }
        await applyFilter()
    }

    public func toggleTLSStatus(_ status: TLSInspectionStatus) async {
        if tlsSelection.contains(status) {
            tlsSelection.remove(status)
        } else {
            tlsSelection.insert(status)
        }
        await applyFilter()
    }

    /// Quita todos los filtros de golpe: es la salida que ofrece el vacío "no matches". Sube también
    /// el eje, porque el tramo al que se bajó era uno de esos filtros.
    public func clearFilters() async {
        searchText = ""
        dateFilter = .anyTime
        protocolSelection = []
        tlsSelection = []
        await applyFilter()
        await reloadUnzoomedAxis()
    }

    /// Si hay algo puesto. Cuenta el texto **aún sin enviar** para que el botón de limpiar no
    /// desaparezca justo cuando el usuario ha escrito algo y no lo ha buscado todavía.
    public var hasActiveFilters: Bool {
        appliedFilter.isActive || !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Derivados

    public var content: TimelineContent { TimelinePresentation.content(for: snapshot) }

    public var footer: TimelineFooter { TimelinePresentation.footer(for: snapshot) }

    /// Qué le toca a la barra de scrub: el eje, nada, o la línea que dice que no se pudo leer.
    public var scrub: ScrubContent { ScrubPresentation.content(for: axis, error: axisError) }

    /// El tramo seleccionado en la barra, si lo hay. Es lo que acota la lista.
    public var selectedInterval: ClosedRange<Date>? { dateFilter.interval }

    /// El tramo que el eje está enseñando, o `nil` si abarca todo el historial. La vista lo fecha en
    /// el pie de la barra: es la respuesta a "¿dónde estoy?".
    public var viewingInterval: ClosedRange<Date>? { zoom.current }

    /// El tramo que la barra resalta, que no es siempre el seleccionado: cuando se ha bajado a él, lo
    /// seleccionado *es* lo dibujado y resaltarlo pintaría el eje entero.
    public var highlightedInterval: ClosedRange<Date>? {
        ScrubPresentation.highlight(dateFilter.interval, viewing: zoom.current)
    }

    /// El preset marcado en el menú, o `nil` si lo que acota es un tramo del eje.
    public var timeRange: TimelineTimeRange? { dateFilter.preset }

    /// Los flujos tal cual. Lo que la lista pinta es `rows`, que es esto mismo con su copia: aquí
    /// llegan quienes necesitan la conexión y no lo que se enseña de ella.
    public var flows: [HistoryFlow] { snapshot.flows }

    /// El Flow Inspector de una fila, o `nil` si el historial no está abierto.
    ///
    /// Nace aquí y no en la vista porque el lector es de este view model y no se expone: la pantalla
    /// de una conexión lee del **mismo** historial ya abierto, no de uno nuevo — abrir un segundo
    /// `FlowStore` sobre la misma BD para leer 500 filas sería pagar dos veces la apertura.
    ///
    /// El `nil` no se puede dar desde una fila (una fila solo existe si hubo lector), pero devolverlo
    /// es más honesto que forzar un lector que quizá no está.
    public func makeInspector(for flow: HistoryFlow) -> FlowInspectorViewModel? {
        reader.map { FlowInspectorViewModel(flow: flow, reader: $0) }
    }

    /// Ejecuta lo que ofrece un hueco de la pantalla.
    public func perform(_ action: TimelineAction) async {
        switch action {
        case .retry:
            await refresh()
        case .clearFilters:
            await clearFilters()
        case .searchFurtherBack:
            // Es la misma paginación que dispara el final de la lista, y tiene que serlo: el filtro
            // sigue puesto y el cursor sigue donde se quedó, así que "seguir buscando" es literalmente
            // leer la siguiente tanda. Un camino propio empezaría de cero y volvería a mirar lo mirado.
            await loadMore()
        }
    }

    // MARK: - Interno

    private func currentFilter() -> HistoryFilter {
        HistoryFilter(
            searchText: searchText,
            protocols: TimelineProtocolFilter.protocols(for: protocolSelection),
            tlsStatuses: tlsSelection,
            dateRange: dateFilter.range(now: now(), calendar: calendar)
        )
    }

    /// Publica un eje recién leído y, con él, si todavía se puede bajar más. Van juntos porque lo
    /// segundo se responde sobre lo primero y depende del tope de barras, que es del lector.
    private func publish(_ axis: ActivityAxis, from reader: HistoryReader) async {
        self.axis = axis
        canZoomFurther = await reader.canZoomFurther(in: axis)
        // Aquí y no en la barra: es el único punto por el que pasa un eje nuevo, así que es donde su
        // copia puede rehacerse una vez por cambio en vez de una vez por fotograma. El acercamiento
        // se lee después de que lo hayan movido quienes llaman: los cuatro caminos que lo cambian
        // (bajar, subir, salir del todo y el tramo caducado) vuelven a pedir el eje al terminar.
        scrubAxis = ScrubPresentation.forAxis(
            axis, zoomed: zoom.isZoomed, zoomable: canZoomFurther
        )
    }

    /// Sube el eje a todo el historial y lo vuelve a pedir, si estaba acercado. Es lo que acompaña a
    /// las acciones que sustituyen el criterio temporal por otro (un preset, o limpiarlo todo): el
    /// tramo deja de mandar, así que el eje no puede seguir dentro de él.
    private func reloadUnzoomedAxis() async {
        guard zoom.isZoomed, let reader = await resolvedReader() else { return }
        zoom.reset()
        scrubNotice = nil
        await loadActivity(from: reader)
    }

    private func applyFilter() async {
        guard let reader = await resolvedReader() else { return }
        let filter = currentFilter()
        guard filter != appliedFilter else { return }
        appliedFilter = filter
        await reader.apply(filter)
    }

    /// Se suscribe a las instantáneas del lector si no lo estaba ya.
    ///
    /// Cualquier carga implica que hay alguien mirando, así que abrir el historial y quedarse sin
    /// suscripción no es un estado válido: es justo lo que pasaba al pulsar "Try again" después de un
    /// fallo de apertura —la carga funcionaba y la pantalla seguía enseñando el error, porque nadie
    /// escuchaba—.
    private func observe(_ reader: HistoryReader) {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in
            for await snapshot in await reader.snapshots() {
                guard let self else { return }
                self.publish(snapshot)
            }
        }
    }

    /// Publica una instantánea y, con ella, las filas que le corresponden.
    ///
    /// Es el **único** sitio donde se escribe `snapshot`, y por eso también el único donde pueden
    /// quedarse desparejadas: cualquier otro camino que la escribiese dejaría la lista pintada con la
    /// copia de la instantánea anterior.
    private func publish(_ snapshot: HistorySnapshot) {
        let flowsChanged = snapshot.flows != self.snapshot.flows
        self.snapshot = snapshot
        // Rehacer la lista es más caro que compararla: cada fila son cuatro búsquedas en el catálogo
        // y cinco cadenas nuevas, y una recarga que no trae nada nuevo es el caso normal (el
        // historial solo se relee cuando alguien lo pide, y casi siempre devuelve lo mismo).
        guard flowsChanged else { return }
        rows = TimelinePresentation.rows(for: snapshot.flows)
    }

    /// El lector, abriéndolo si hace falta. Publica el fallo y devuelve `nil` si no se pudo.
    private func resolvedReader() async -> HistoryReader? {
        if let reader { return reader }

        let task = openTask ?? Task { [makeReader] in try await makeReader() }
        openTask = task
        do {
            let reader = try await task.value
            self.reader = reader
            observe(reader)
            return reader
        } catch {
            // Se olvida la tarea fallida: si no, el siguiente "Try again" devolvería el mismo error
            // cacheado sin haber vuelto a intentar nada.
            openTask = nil
            publish(
                HistorySnapshot(
                    filter: appliedFilter,
                    state: .failed(HistoryError.classifying(error))
                )
            )
            return nil
        }
    }
}
