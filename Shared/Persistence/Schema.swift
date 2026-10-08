import Foundation
import GRDB

/// Definición del esquema SQLite y sus migraciones. Es la única fuente de verdad del layout
/// de columnas; `FlowStore` (lectura/escritura) serializa los tipos de dominio contra estas
/// columnas. Ver `docs/spec/persistence.md`.
public enum Schema {

    /// Migrador con el esquema versionado. Añadir cambios de esquema como migraciones nuevas
    /// (`v2`, `v3`, ...) — nunca editar una migración ya publicada, para no romper BDs existentes.
    public static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "flows") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("proto", .integer).notNull()
                // Las direcciones se guardan como blob crudo (4 bytes v4, 16 v6): una sola columna
                // sirve para ambas familias y la longitud desambigua la versión.
                t.column("addr_a", .blob).notNull()
                t.column("port_a", .integer).notNull()
                t.column("addr_b", .blob).notNull()
                t.column("port_b", .integer).notNull()
                t.column("first_seen", .integer).notNull()
                t.column("last_seen", .integer).notNull()
                t.column("bytes_out", .integer).notNull().defaults(to: 0)
                t.column("bytes_in", .integer).notNull().defaults(to: 0)
                t.column("packet_count", .integer).notNull().defaults(to: 0)
                t.column("tls_status", .integer).notNull()
                t.column("sni", .text)
            }
            // Índice para la consulta principal de la app (flujos recientes por `last_seen`).
            try db.create(index: "flows_last_seen", on: "flows", columns: ["last_seen"])
            // Índice único sobre la 5-tupla canónica: habilita el UPSERT por flujo
            // (`ON CONFLICT`) y las búsquedas `flow(matching:)` sin escaneo.
            try db.create(
                index: "flows_tuple",
                on: "flows",
                columns: ["proto", "addr_a", "port_a", "addr_b", "port_b"],
                options: [.unique]
            )

            try db.create(table: "packets") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("flow_id", .integer).notNull()
                    .references("flows", onDelete: .cascade)
                t.column("ts", .integer).notNull()
                t.column("direction", .integer).notNull()
                t.column("length", .integer).notNull()
                t.column("tcp_flags", .integer).notNull().defaults(to: 0)
                t.column("pcap_offset", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "packets_flow_id", on: "packets", columns: ["flow_id"])
        }

        // v2 — los instantes en disco pasan a ser **absolutos** (ns desde el epoch) y cada flujo
        // recuerda en qué sesión de captura se vio.
        //
        // Por qué: en v1 las columnas de tiempo guardaban el sello monotónico crudo
        // (`CLOCK_UPTIME_RAW`), que se reinicia con el dispositivo. Un historial así no se puede
        // fechar (un flujo de anteayer y otro de hoy comparten rango de valores) ni ordenar entre
        // arranques, y la retención por antigüedad de Ajustes → Almacenamiento sería directamente
        // incorrecta. Desde v2 el `FlowStore` convierte al escribir, con el ancla que toma al abrir.
        migrator.registerMigration("v2") { db in
            // Las filas de v1 llevan sellos monotónicos que ya no se pueden fechar: no existe el
            // ancla de la sesión que las escribió. Se descartan en vez de reinterpretarlas como
            // epoch, que las situaría en 1970 y mentiría en la Timeline. El cascade borra sus
            // paquetes. (No hay ninguna instalación desplegada; esto solo afecta a BDs de desarrollo.)
            try db.execute(sql: "DELETE FROM flows")

            // Sesión de captura en la que se vio el flujo: el instante de apertura del store, en ns
            // desde el epoch. Es un discriminador, no una fecha que se enseñe.
            try db.alter(table: "flows") { t in
                t.add(column: "session", .integer).notNull().defaults(to: 0)
            }

            // La 5-tupla deja de ser única por sí sola: la misma pasa a ser un flujo distinto en
            // cada sesión. Los puertos efímeros se reciclan, así que sin esto dos conexiones de días
            // distintos se fusionarían en una sola fila con una duración inventada.
            try db.drop(index: "flows_tuple")
            try db.create(
                index: "flows_session_tuple",
                on: "flows",
                columns: ["session", "proto", "addr_a", "port_a", "addr_b", "port_b"],
                options: [.unique]
            )
        }

        // v3 — cada paquete recuerda **en qué fichero** de captura están sus bytes, no solo en qué
        // posición.
        //
        // Por qué: `pcap_offset` es el offset del registro dentro de *su* fichero, y el writer rota
        // a uno nuevo al superar su tope de tamaño, reiniciando los offsets tras la cabecera global.
        // Sin el fichero, un offset guardado no identifica unos bytes: apunta a una posición de un
        // fichero desconocido, y el salto paquete→bytes del Flow Inspector llevaría a otra conexión.
        migrator.registerMigration("v3") { db in
            try db.alter(table: "packets") { t in
                t.add(column: "pcap_file", .integer).notNull().defaults(to: 0)
            }

            // Las filas anteriores llevan offset pero no fichero, así que su offset no señala nada.
            // Se anula (que es como se representa "sin captura") en vez de dejarlo apuntando al
            // fichero 0, que sería inventarle unos bytes. Los metadatos del paquete se conservan:
            // lo único que se pierde es el enlace a la captura, que nunca fue resoluble.
            try db.execute(sql: "UPDATE packets SET pcap_offset = 0")
        }

        // v4 — índice por instante en `packets`.
        //
        // Por qué: la barra de scrub de la Timeline cuenta paquetes por intervalo sobre **todo** el
        // historial (`FlowStore.packetCounts`), y hasta aquí la tabla solo estaba indexada por
        // `flow_id`. Sin este índice, dibujar el eje sería un escaneo completo de la tabla más
        // grande de la BD —la que crece con cada paquete capturado— cada vez que se abre la
        // pantalla. Es el mismo motivo por el que `flows` tiene `flows_last_seen` desde v1.
        migrator.registerMigration("v4") { db in
            try db.create(index: "packets_ts", on: "packets", columns: ["ts"])
        }

        // v5 — el índice del **contenido descifrado**: qué trozo de qué conversación está en qué
        // fichero y en qué posición.
        //
        // Por qué una tabla y no una columna en `packets`: un trozo de plaintext no es un paquete.
        // Sale de un stream ya reensamblado y descifrado, así que no tiene correspondencia 1:1 con
        // ningún datagrama —un registro puede abarcar varios segmentos, y un segmento retransmitido no
        // produce ninguno—, y colgarlo de una fila de `packets` obligaría a elegir arbitrariamente cuál.
        //
        // Los bytes **no** están aquí: viven en ficheros propios (`docs/spec/plaintext.md`). SQLite no
        // devuelve el espacio al borrar filas, así que una BD que engordase con contenido descifrado no
        // podría adelgazar al caducar — y este contenido caduca antes que ningún otro (ADR 0007).
        migrator.registerMigration("v5") { db in
            try db.create(table: "plaintext") { t in
                t.autoIncrementedPrimaryKey("id")
                // El cascade es la mitad barata de la retención: borrar un flujo se lleva su
                // contenido descifrado sin que nadie tenga que acordarse. La otra mitad —que el
                // plaintext caduque **antes** que el flujo— es un borrado propio por `ts`.
                t.column("flow_id", .integer).notNull()
                    .references("flows", onDelete: .cascade)
                t.column("ts", .integer).notNull()
                t.column("direction", .integer).notNull()
                // La conversación dentro del fichero. Se guarda para poder validar que el registro
                // que hay en esa posición es el que se buscaba.
                t.column("stream", .integer).notNull()
                t.column("file_seq", .integer).notNull()
                // `offset` es palabra reservada de SQL: el nombre lleva prefijo a propósito.
                t.column("record_offset", .integer).notNull()
                t.column("stored_length", .integer).notNull()
                t.column("original_length", .integer).notNull()
            }
            // La consulta de la pantalla: los trozos de un flujo, en orden.
            try db.create(index: "plaintext_flow_id", on: "plaintext", columns: ["flow_id", "ts"])
            // La del barrido por antigüedad, que corta por `ts` sobre toda la tabla — el mismo motivo
            // por el que `packets` tiene `packets_ts` desde v4.
            try db.create(index: "plaintext_ts", on: "plaintext", columns: ["ts"])
        }

        // v6 — los **proyectos y sesiones de auditoría** (ADR 0008), y a qué sesión pertenece cada
        // flujo.
        //
        // Por qué una columna nueva y no la `session` que `flows` ya tiene: aquélla es la sesión de
        // **captura** —el instante en que se abrió el store, un discriminador de la clave única— y
        // ésta es una grabación que una persona abre, nombra y cierra. Una sesión de auditoría puede
        // abarcar varias de captura (el túnel se reinicia en medio) y la mayoría de las de captura
        // no pertenecen a ninguna.
        migrator.registerMigration("v6") { db in
            try db.create(table: "audit_projects") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("bundle_id", .text)
                t.column("catalogue_version", .text)
                t.column("created_at", .integer).notNull()
            }

            try db.create(table: "audit_allowlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("project_id", .integer).notNull()
                    .references("audit_projects", onDelete: .cascade)
                // El orden en que se escribió, que el `rowid` no garantiza si la lista se reescribe.
                t.column("position", .integer).notNull()
                // La forma canónica de `DomainPattern.text`: ya normalizada, así que la unicidad
                // de abajo no depende de mayúsculas ni de un punto final.
                t.column("pattern", .text).notNull()
                t.column("note", .text)
                t.uniqueKey(["project_id", "pattern"])
            }

            try db.create(table: "audit_sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("project_id", .integer).notNull()
                    .references("audit_projects", onDelete: .cascade)
                t.column("kind", .integer).notNull()
                // Solo las tiene una sesión de auditoría; una baseline se graba sin la app.
                t.column("app_version", .text)
                t.column("build_number", .text)
                t.column("device_model", .text).notNull()
                t.column("os_version", .text).notNull()
                t.column("tool_version", .text).notNull()
                t.column("inspection_enabled", .boolean).notNull()
                t.column("ca_trusted", .boolean).notNull()
                t.column("started_at", .integer).notNull()
                t.column("ended_at", .integer)
                t.column("notes", .text).notNull()
            }
            try db.create(
                index: "audit_sessions_project", on: "audit_sessions", columns: ["project_id", "started_at"]
            )
            // Como mucho **una** sesión abierta en toda la BD. No es solo higiene: `upsertFlow`
            // etiqueta cada flujo nuevo con «la sesión abierta», y con dos esa frase no significa
            // nada. La regla vive en el esquema porque escriben dos procesos.
            try db.execute(sql: """
                CREATE UNIQUE INDEX audit_sessions_single_open
                ON audit_sessions ((ended_at IS NULL)) WHERE ended_at IS NULL
                """)

            try db.create(table: "audit_markers") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("session_id", .integer).notNull()
                    .references("audit_sessions", onDelete: .cascade)
                t.column("ts", .integer).notNull()
                t.column("kind", .integer).notNull()
                // Solo para el marcador libre.
                t.column("label", .text)
            }
            try db.create(index: "audit_markers_session", on: "audit_markers", columns: ["session_id", "ts"])

            // `SET NULL` y no cascade: borrar una sesión de auditoría retira la etiqueta, no el
            // historial. El flujo ocurrió igual, y la Timeline no tiene por qué perderlo porque
            // alguien descartó un proyecto.
            try db.alter(table: "flows") { t in
                t.add(column: "audit_session_id", .integer)
                    .references("audit_sessions", onDelete: .setNull)
            }
            try db.create(
                index: "flows_audit_session", on: "flows", columns: ["audit_session_id", "first_seen"]
            )
        }

        // v7 — el **nombre que el DNS le había dado** a la dirección remota de un flujo, y los demás
        // nombres que esa dirección tenía vivos.
        //
        // Por qué columnas propias y no la `sni`: un SNI lo anuncia la conexión y esto se deduce de
        // una búsqueda anterior sobre una dirección que puede ser compartida. Mezclarlos haría que un
        // informe no pudiera decir cuál de las dos cosas está afirmando. El origen del nombre de un
        // flujo no necesita columna: es cuál de las dos está puesta (`FlowName`).
        migrator.registerMigration("v7") { db in
            try db.alter(table: "flows") { t in
                t.add(column: "dns_name", .text)
                // Los otros candidatos, del más reciente al más antiguo, separados por un espacio.
                // Un nombre del mapa no puede llevar uno —`DomainPattern` es su vara de medir—, así
                // que el separador no necesita escape. `NULL` es «sin competencia».
                t.add(column: "dns_other_names", .text)
            }
        }

        // v8 — lo que el **servidor contestó** al ClientHello de un flujo: la versión y la suite de
        // su ServerHello, o la alerta con la que se negó.
        //
        // Son los valores del cable, enteros sin tabla detrás: los elige el otro extremo, y un
        // borrador o una suite sin asignar es evidencia que se guarda como llegó. Las cuatro son
        // `NULL` en un flujo sin lectura, que no es lo mismo que una lectura con malas noticias:
        // `tls_alert` existe para que «el servidor se negó» no se confunda con «no se miró».
        migrator.registerMigration("v8") { db in
            try db.alter(table: "flows") { t in
                t.add(column: "tls_version", .integer)
                t.add(column: "tls_cipher_suite", .integer)
                // 1 si la versión y la suite salieron de un HelloRetryRequest y no del ServerHello
                // definitivo. `NULL` cuando no hay versión de la que decirlo.
                t.add(column: "tls_hello_retry", .integer)
                // El código de la alerta. Excluye a las otras tres: o negoció o se negó.
                t.add(column: "tls_alert", .integer)
            }
        }

        // v9 — lo que un flujo llevaba acumulado **antes de que la tabla en memoria lo volviera a
        // crear**.
        //
        // Por qué: un record trae los totales de la vida actual del flujo en la tabla, y la tabla
        // lo suelta por inactividad, por desalojo o por un RST. Si esa 5-tupla vuelve a tener
        // tráfico nace otra vez desde cero, y fijar la fila a sus totales —lo que hacía el upsert—
        // borraba todo lo anterior: una conexión que había movido megas pasaba a constar con un
        // paquete. Estas tres columnas guardan el punto de partida de la vida en curso, así que el
        // total de la fila es base + lo que diga el record (`FlowStore.upsertFlow`).
        migrator.registerMigration("v9") { db in
            try db.alter(table: "flows") { t in
                t.add(column: "base_bytes_out", .integer).notNull().defaults(to: 0)
                t.add(column: "base_bytes_in", .integer).notNull().defaults(to: 0)
                t.add(column: "base_packet_count", .integer).notNull().defaults(to: 0)
            }
        }

        // v10 — de dónde salió la versión y la suite de un flujo: del ServerHello que viajó en
        // claro hacia el dispositivo, o de la conexión que el túnel abrió contra el servidor real
        // para inspeccionarlo.
        //
        // Por qué una columna y no deducirlo de `tls_status`: un flujo que rechazó nuestro leaf
        // (`notInspectable`) o cuya terminación falló a medias (`encrypted`) puede llevar la
        // cifra de la conexión de subida, que negoció antes. Y son respuestas a ClientHellos
        // distintos —el de la app y el nuestro—, cosa que un informe tiene que poder decir.
        //
        // 1 es la conexión de subida. `NULL` cuando no hay versión de la que decirlo, y también
        // en las filas anteriores a esta migración, que se leen como ServerHello: hasta aquí era
        // lo único que escribía una versión.
        migrator.registerMigration("v10") { db in
            try db.alter(table: "flows") { t in
                t.add(column: "tls_upstream", .integer)
            }
        }

        // v11 — lo que el **cliente** ofreció en su ClientHello: versiones de TLS y ALPN.
        //
        // Por qué dos columnas para las versiones: el ClientHello las dice de dos formas que no
        // significan lo mismo. `tls_offered_versions` es la lista de `supported_versions` (exacta);
        // `tls_offered_legacy` es el `legacy_version` de un ClientHello sin esa extensión, que es
        // un techo y no dice qué acepta por debajo. Una fila con oferta tiene **exactamente una**
        // de las dos, y esa pareja es lo que dice si hay oferta: las otras tres columnas no valen
        // para saberlo (un cliente sin ALPN las deja como una fila sin lectura).
        //
        // Las listas son texto separado por espacios: las versiones, por su valor del cable en
        // decimal; los protocolos, tal cual, que el escáner solo deja pasar ASCII imprimible sin
        // espacios. Una lista de versiones vacía es `''`, no `NULL`: la extensión estaba y no
        // ofrecía nada.
        migrator.registerMigration("v11") { db in
            try db.alter(table: "flows") { t in
                t.add(column: "tls_offered_versions", .text)
                t.add(column: "tls_offered_legacy", .integer)
                t.add(column: "tls_offered_alpn", .text)
                // Cuántos identificadores de ALPN mandó el cliente que no están en la columna
                // anterior. `NULL` sin oferta.
                t.add(column: "tls_offered_alpn_omitted", .integer)
                // 1 si el ClientHello llevaba `encrypted_client_hello`: lo leído es el exterior.
                t.add(column: "tls_offered_ech", .integer)
            }
        }

        // v12 — la versión de QUIC de un flujo, leída de la cabecera larga de sus primeros
        // paquetes, y de qué extremo salió.
        //
        // `quic_version` es el valor del cable, cuatro bytes sin interpretar: cabe de sobra en un
        // entero de SQLite. `quic_from_server` es 1 si la cabecera la mandó el servidor —la
        // versión en uso— y 0 si solo se vio la que propuso el cliente. Las dos son `NULL` sin
        // lectura, y van siempre juntas.
        //
        // No hay columna para «es QUIC y va cifrado»: eso ya lo dice `tls_status`, que la tabla de
        // flujos sube a `encrypted` cuando la versión es una de las que se sabe que cifran.
        migrator.registerMigration("v12") { db in
            try db.alter(table: "flows") { t in
                t.add(column: "quic_version", .integer)
                t.add(column: "quic_from_server", .integer)
            }
        }

        // v13 — lo que se leyó del certificado del servidor en un flujo de TLS ≤ 1.2, que lo
        // manda en claro detrás del ServerHello.
        //
        // `tls_chain_state` dice qué se leyó (`FlowStore.Serialization.ChainState`): una cadena
        // entera, una cadena de la que solo se guarda el principio, o que el handshake siguió
        // sin certificado y por qué. `NULL` es que no hubo lectura, **y no dice el motivo**: que
        // un flujo de TLS 1.3 la lleva cifrada se deduce de `tls_version`, no se apunta aquí.
        //
        // `tls_chain` son los certificados, en el orden en que se mandaron, como un array JSON
        // de `{subject, subjectTruncated, issuer, issuerTruncated, notAfter}` (`notAfter` en
        // segundos desde 1970). Es JSON y no una lista separada por espacios como las demás
        // porque un sujeto es texto que elige el servidor y puede llevar cualquier carácter.
        // `NULL` cuando el estado no es una cadena.
        migrator.registerMigration("v13") { db in
            try db.alter(table: "flows") { t in
                t.add(column: "tls_chain_state", .integer)
                t.add(column: "tls_chain", .text)
            }
        }

        return migrator
    }
}
