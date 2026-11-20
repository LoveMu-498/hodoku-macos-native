/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HODOKU_LOGIC_H
#define HODOKU_LOGIC_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef uint8_t (*HodokuLogicCancelled)(void *context);
typedef void (*HodokuLogicReceive)(void *context, const uint8_t *bytes, size_t count);
typedef struct {
    uint32_t ending; /* 0 solved, 1 stalled, 2 unsupported, 3 rejected, 4 cancelled, 5 first step, 6 contradiction after committed removal, 7 ungradable baseline search */
    uint32_t difficulty;
    int32_t score;
} HodokuLogicResult;
/* All pointers borrowed for this call, callbacks synchronous on the calling thread.
   Config is UTF-8, one Java rule per line: name,level,score,trained. Inactive training
   rules may be supplied as @name. Search options use %key=value on separate lines.
   Thresholds are the six Java difficulty maxima. Each receive callback delivers one
   UTF-8 step with 20 pipe-separated fields in phase5/ffi.rs Step::record order.
   Candidate lists keep order and duplicates. Indices are zero-based. */
int32_t hodoku_logic_v1(const uint8_t *values, const uint16_t *masks, const uint8_t *fixed, size_t cells,
    const uint8_t *config, size_t config_bytes, const int32_t *thresholds, size_t levels,
    uint32_t max_level, uint32_t flags, void *context, HodokuLogicCancelled cancel,
    HodokuLogicReceive receive, HodokuLogicResult *result);
/* Borrow the immutable Options.DEFAULT_SOLVER_STEPS table for the life of the process. */
const uint8_t *hodoku_logic_default_rules_v1(size_t *length);
/* flags: 1 generate initial Java FIFO from givens, 2 reject below band, 4 first step only, 8 require all uniqueness candidates, 16 allow overlapping ALS, 32 retain alternative ALS, 64 enumerate named instances (one rule). */
#ifdef __cplusplus
}
#endif
#endif
