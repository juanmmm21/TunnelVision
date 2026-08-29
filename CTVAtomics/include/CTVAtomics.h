#ifndef CTV_ATOMICS_H
#define CTV_ATOMICS_H

#include <stdint.h>
#include <stddef.h>

/*
 * Cabecera del ring buffer SPSC mapeado en memoria compartida (contenedor del App Group).
 *
 * Toda la sincronización cross-proceso pasa por estas funciones: `head`, `tail` y `dropped`
 * se acceden con órdenes de memoria explícitas (C11 <stdatomic.h>), único punto del módulo
 * donde se tocan esos campos. El lado Swift trata la región mapeada como opaca (`void *`) y
 * nunca lee/escribe la cabecera directamente, de modo que el tipo `_Atomic` no cruza al import
 * de Swift y el layout queda gobernado por C.
 *
 * Contrato SPSC: exactamente un productor escribe `head`, exactamente un consumidor escribe
 * `tail`. Con ese contrato no hacen falta locks; el productor publica con release y el
 * consumidor observa con acquire.
 */

/* Tamaño reservado (alineado a línea de caché) antes del array de slots. */
size_t tvring_header_bytes(void);

/* Inicializa la cabecera: fija magic/version/slot_size/slot_count y pone head/tail/dropped a 0. */
void tvring_init(void *base, uint32_t magic, uint32_t version, uint32_t slot_size, uint32_t slot_count);

uint32_t tvring_magic(const void *base);
uint32_t tvring_version(const void *base);
uint32_t tvring_slot_size(const void *base);
uint32_t tvring_slot_count(const void *base);

/* `head` lo escribe el productor (release) y lo lee el consumidor (acquire). */
uint64_t tvring_head_relaxed(const void *base);
uint64_t tvring_head_acquire(const void *base);
void tvring_head_store_release(void *base, uint64_t value);

/* `tail` lo escribe el consumidor (release) y lo lee el productor (acquire). */
uint64_t tvring_tail_relaxed(const void *base);
uint64_t tvring_tail_acquire(const void *base);
void tvring_tail_store_release(void *base, uint64_t value);

/* `dropped` lo incrementa el productor al desbordar; el consumidor lo lee como estadística. */
uint64_t tvring_dropped_relaxed(const void *base);
void tvring_dropped_incr(void *base);

#endif /* CTV_ATOMICS_H */
