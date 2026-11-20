/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HODOKU_ENGINE_H
#define HODOKU_ENGINE_H
#include <stddef.h>
#include <stdint.h>
#include "HodokuChain.h"
#include "HodokuLogic.h"
#include "HodokuGeneration.h"
#include "HodokuReplay.h"
#ifdef __cplusplus
extern "C" {
#endif

#define HODOKU_ENGINE_ABI_VERSION 1u
#define HODOKU_DEFAULT_MAX_TRIES 1000000
#define HODOKU_EXHAUSTED 0u
#define HODOKU_SOLUTION_BOUND 1u
#define HODOKU_LIMIT 2u
#define HODOKU_CANCELLED 3u

typedef struct HodokuCancellation HodokuCancellation;
typedef struct {
    uint32_t termination;
    uint32_t count;
    uint32_t tries;
    /* Verified solution only for EXHAUSTED with count == 1; otherwise all zeros. */
    uint8_t solution[81];
} HodokuCountResult;

uint32_t hodoku_engine_abi_version(void);
HodokuCancellation *hodoku_cancellation_new(void);
/* Sticky and thread-safe. NULL is accepted. Free only after all users finish. */
void hodoku_cancellation_request(HodokuCancellation *token);
void hodoku_cancellation_free(HodokuCancellation *token);

/* Row-major 81 digits, zero is empty. Ordinary candidate masks are optional:
   NULL/0 derives legal candidates. Otherwise supply 81 masks, digit 1 in bit 0,
   zero for filled cells. A missing candidate excludes that digit from search.
   max_solutions is the Java threshold: for threshold 1 stop on solution 2.
   max_tries counts guesses. Both limits must be nonnegative.
   Buffers must be valid, aligned, nonoverlapping and live for this call.
   Return 0 on success, 1 for invalid input, 2 for an internal error. Ignore
   the output on error. The engine retains no buffers or token references. */
int32_t hodoku_count_solutions_v1(const uint8_t *values, size_t value_count,
    const uint16_t *candidates, size_t candidate_count, int32_t max_solutions,
    int32_t max_tries, const HodokuCancellation *cancel, HodokuCountResult *out);

/* Default Java technique order through locked candidates type 2. Cell numbers
   are row-major 0..80. Houses are rows 0..8, columns 9..17 and boxes 18..26.
   255 means no house/placement. Digits and deletions use bit zero for 1. */
#define HODOKU_HINT_NONE 0u
#define HODOKU_HINT_FULL_HOUSE 1u
#define HODOKU_HINT_NAKED_SINGLE 2u
#define HODOKU_HINT_HIDDEN_SINGLE 3u
#define HODOKU_HINT_LOCKED_PAIR 4u
#define HODOKU_HINT_LOCKED_TRIPLE 5u
#define HODOKU_HINT_POINTING 6u
#define HODOKU_HINT_CLAIMING 7u

typedef struct {
    uint8_t technique;
    uint8_t house;
    uint16_t digits;
    uint8_t premise_count;
    uint8_t premises[9];
    uint8_t placement_cell;
    uint8_t placement_digit;
    uint16_t deletions[81];
} HodokuHintStep;

/* Requires the 81 ordinary candidate masks from this exact position.
   On success (0), technique 0 means none of the supported steps applies.
   Invalid/locally contradictory snapshots return 1; internal error 2.
   The same buffer lifetime/alignment rules as count apply. */
int32_t hodoku_next_step_v1(const uint8_t *values, size_t value_count,
    const uint16_t *candidates, size_t candidate_count, HodokuHintStep *out);

/* Search each supported instance for an exact footprint using Box priority.
   selected_cells contains 1..81 distinct cell indices, in any order. */
int32_t hodoku_step_for_cells_v1(const uint8_t *values, size_t value_count,
    const uint16_t *candidates, size_t candidate_count, const uint8_t *selected_cells,
    size_t selected_count, HodokuHintStep *out);

/* All supported named instances. Callbacks run synchronously, grouped by
   technique in Java order. The pointer to each step expires after its callback. */
typedef void (*HodokuHintVisitor)(void *context, const HodokuHintStep *step);
int32_t hodoku_hint_catalog_v1(const uint8_t *values, size_t value_count,
    const uint16_t *candidates, size_t candidate_count, HodokuHintVisitor visit, void *context);

#ifdef __cplusplus
}
#endif
#endif
