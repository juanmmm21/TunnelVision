#include "CTVAtomics.h"
#include <stdatomic.h>

/*
 * Layout binario de la cabecera del ring. Los tres índices son `_Atomic` para que las
 * operaciones con orden de memoria explícito sean correctas entre procesos que comparten
 * el mapeo. Definido aquí (no en el header) para que Swift nunca vea el tipo `_Atomic`.
 */
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t slot_size;
    uint32_t slot_count;
    _Atomic uint64_t head;
    _Atomic uint64_t tail;
    _Atomic uint64_t dropped;
} TVRingHeader;

size_t tvring_header_bytes(void) {
    /* 64 >= sizeof(TVRingHeader) (40 B) y alinea los slots a línea de caché. */
    return 64;
}

void tvring_init(void *base, uint32_t magic, uint32_t version, uint32_t slot_size, uint32_t slot_count) {
    TVRingHeader *h = (TVRingHeader *)base;
    h->magic = magic;
    h->version = version;
    h->slot_size = slot_size;
    h->slot_count = slot_count;
    atomic_store_explicit(&h->head, 0, memory_order_relaxed);
    atomic_store_explicit(&h->tail, 0, memory_order_relaxed);
    atomic_store_explicit(&h->dropped, 0, memory_order_relaxed);
}

uint32_t tvring_magic(const void *base) { return ((const TVRingHeader *)base)->magic; }
uint32_t tvring_version(const void *base) { return ((const TVRingHeader *)base)->version; }
uint32_t tvring_slot_size(const void *base) { return ((const TVRingHeader *)base)->slot_size; }
uint32_t tvring_slot_count(const void *base) { return ((const TVRingHeader *)base)->slot_count; }

uint64_t tvring_head_relaxed(const void *base) {
    return atomic_load_explicit(&((const TVRingHeader *)base)->head, memory_order_relaxed);
}

uint64_t tvring_head_acquire(const void *base) {
    return atomic_load_explicit(&((const TVRingHeader *)base)->head, memory_order_acquire);
}

void tvring_head_store_release(void *base, uint64_t value) {
    atomic_store_explicit(&((TVRingHeader *)base)->head, value, memory_order_release);
}

uint64_t tvring_tail_relaxed(const void *base) {
    return atomic_load_explicit(&((const TVRingHeader *)base)->tail, memory_order_relaxed);
}

uint64_t tvring_tail_acquire(const void *base) {
    return atomic_load_explicit(&((const TVRingHeader *)base)->tail, memory_order_acquire);
}

void tvring_tail_store_release(void *base, uint64_t value) {
    atomic_store_explicit(&((TVRingHeader *)base)->tail, value, memory_order_release);
}

uint64_t tvring_dropped_relaxed(const void *base) {
    return atomic_load_explicit(&((const TVRingHeader *)base)->dropped, memory_order_relaxed);
}

void tvring_dropped_incr(void *base) {
    atomic_fetch_add_explicit(&((TVRingHeader *)base)->dropped, 1, memory_order_relaxed);
}
