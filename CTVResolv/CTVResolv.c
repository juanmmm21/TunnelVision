#include "CTVResolv.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <resolv.h>
#include <string.h>
#include <sys/socket.h>

int ctv_copy_system_resolvers(char *out, int max_servers) {
    if (out == NULL || max_servers <= 0) {
        return -1;
    }
    if (max_servers > CTV_RESOLV_MAX_SERVERS) {
        max_servers = CTV_RESOLV_MAX_SERVERS;
    }

    /*
     * Se usa el estado *propio* (`res_ninit` sobre una struct local) y no el global `_res`: el
     * global es por hilo y lo comparte con quien sea que esté resolviendo en el proceso, así que
     * inicializarlo aquí pisaría el suyo. Este se destruye al salir, pase lo que pase.
     */
    struct __res_state state;
    memset(&state, 0, sizeof(state));
    if (res_ninit(&state) != 0) {
        res_ndestroy(&state);
        return -1;
    }

    union res_sockaddr_union servers[CTV_RESOLV_MAX_SERVERS];
    memset(servers, 0, sizeof(servers));
    int found = res_getservers(&state, servers, max_servers);
    if (found < 0) {
        res_ndestroy(&state);
        return -1;
    }
    if (found > max_servers) {
        found = max_servers;
    }

    int written = 0;
    for (int i = 0; i < found; i++) {
        char *slot = out + (size_t)written * CTV_RESOLV_ADDRESS_LENGTH;
        const char *text = NULL;

        /*
         * `res_getservers` rellena huecos con familia 0 cuando el sistema tiene menos de los que
         * se piden, así que la familia es lo que dice si una entrada existe — no el índice.
         */
        if (servers[i].sin.sin_family == AF_INET) {
            text = inet_ntop(AF_INET, &servers[i].sin.sin_addr, slot, CTV_RESOLV_ADDRESS_LENGTH);
        } else if (servers[i].sin6.sin6_family == AF_INET6) {
            text = inet_ntop(AF_INET6, &servers[i].sin6.sin6_addr, slot, CTV_RESOLV_ADDRESS_LENGTH);
        }

        if (text != NULL) {
            written++;
        } else {
            /* Una entrada ilegible no invalida las demás: se salta y se deja el hueco limpio. */
            memset(slot, 0, CTV_RESOLV_ADDRESS_LENGTH);
        }
    }

    res_ndestroy(&state);
    return written;
}
