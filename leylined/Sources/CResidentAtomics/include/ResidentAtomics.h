#ifndef LEYLINE_RESIDENT_ATOMICS_H
#define LEYLINE_RESIDENT_ATOMICS_H
#include <stdbool.h>
#include <stdint.h>

// @canonical resident_atomics -- C11 atomics preserve the macOS 14 deployment
// floor. Swift Synchronization.Atomic requires macOS 15 on this toolchain.
typedef struct LeylineAtomicUInt64 LeylineAtomicUInt64;
LeylineAtomicUInt64 *leyline_atomic_create(uint64_t value);
void leyline_atomic_destroy(LeylineAtomicUInt64 *value);
uint64_t leyline_atomic_load(LeylineAtomicUInt64 *value);
void leyline_atomic_store(LeylineAtomicUInt64 *value, uint64_t desired);
uint64_t leyline_atomic_exchange(LeylineAtomicUInt64 *value, uint64_t desired);
bool leyline_atomic_compare_exchange(LeylineAtomicUInt64 *value, uint64_t expected, uint64_t desired);
uint64_t leyline_atomic_add(LeylineAtomicUInt64 *value, uint64_t amount);
#endif
