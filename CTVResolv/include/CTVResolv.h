#ifndef CTV_RESOLV_H
#define CTV_RESOLV_H

#include <stddef.h>

/*
 * Lectura de los resolvers de DNS que el sistema tiene configurados ahora mismo.
 *
 * Existe como shim en C porque `<resolv.h>` no forma parte de ningún módulo que Swift pueda
 * importar en el SDK de iOS: no hay `import resolv`, ni los símbolos `res_9_*` son visibles desde
 * `Darwin`. Es el mismo motivo por el que existe `CTVAtomics` — algo que solo se puede decir en C
 * se dice en C y cruza a Swift por una frontera estrecha.
 *
 * La frontera es deliberadamente tonta: devuelve **texto** (forma de presentación, la que espera
 * `NEDNSSettings.servers`) y no `sockaddr`, para que ninguna estructura de red cruce el import y
 * para que la parte que decide *cuáles* de esos resolvers se pueden anunciar sea Swift puro y
 * testable (`TunnelResolvers`, en `Shared/Models`).
 */

/* Máximo de resolvers que el sistema rastrea (`MAXNS` de <resolv.h>). */
#define CTV_RESOLV_MAX_SERVERS 3

/* Bytes por dirección en el buffer de salida: `INET6_ADDRSTRLEN`, terminador incluido. */
#define CTV_RESOLV_ADDRESS_LENGTH 46

/*
 * Copia las direcciones de los resolvers configurados en `out`, como cadenas terminadas en NUL
 * colocadas cada `CTV_RESOLV_ADDRESS_LENGTH` bytes.
 *
 * `out` debe tener sitio para `max_servers * CTV_RESOLV_ADDRESS_LENGTH` bytes.
 *
 * Devuelve cuántas direcciones escribió, o **-1 si la configuración no se pudo leer**. Los dos
 * casos se distinguen a propósito: "el sistema no tiene resolvers" (0) y "no pudimos preguntar"
 * (-1) llevan a decisiones distintas río arriba.
 */
int ctv_copy_system_resolvers(char *out, int max_servers);

#endif /* CTV_RESOLV_H */
