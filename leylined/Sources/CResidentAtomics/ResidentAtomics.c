#include "ResidentAtomics.h"
#include <stdatomic.h>
#include <stdlib.h>

struct LeylineAtomicUInt64 { _Atomic(uint64_t) value; };
LeylineAtomicUInt64 *leyline_atomic_create(uint64_t value) {
    LeylineAtomicUInt64 *storage = malloc(sizeof(*storage));
    if (!storage) abort();
    atomic_init(&storage->value, value);
    // Failing this platform requirement must never conceal a mutex in a tap
    // callback whose independent release guarantee depends on lock-free reads.
    if (!atomic_is_lock_free(&storage->value)) abort();
    return storage;
}
void leyline_atomic_destroy(LeylineAtomicUInt64 *value) { free(value); }
uint64_t leyline_atomic_load(LeylineAtomicUInt64 *value) {
    return atomic_load_explicit(&value->value, memory_order_acquire);
}
void leyline_atomic_store(LeylineAtomicUInt64 *value, uint64_t desired) {
    atomic_store_explicit(&value->value, desired, memory_order_release);
}
uint64_t leyline_atomic_exchange(LeylineAtomicUInt64 *value, uint64_t desired) {
    return atomic_exchange_explicit(&value->value, desired, memory_order_acq_rel);
}
bool leyline_atomic_compare_exchange(LeylineAtomicUInt64 *value, uint64_t expected, uint64_t desired) {
    return atomic_compare_exchange_strong_explicit(&value->value, &expected, desired,
                                                  memory_order_acq_rel, memory_order_acquire);
}
uint64_t leyline_atomic_add(LeylineAtomicUInt64 *value, uint64_t amount) {
    return atomic_fetch_add_explicit(&value->value, amount, memory_order_acq_rel);
}
