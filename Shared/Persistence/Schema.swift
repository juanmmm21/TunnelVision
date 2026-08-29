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

        return migrator
    }
}
