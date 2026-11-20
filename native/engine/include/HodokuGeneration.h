/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HODOKU_GENERATION_H
#define HODOKU_GENERATION_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Returns 0 with 81 row-major clue digits, 1 on cancellation, 2 on search
   limit, 3 on rejected pattern, 4 on invalid ABI arguments, 5 on internal
   failure. No output is written on failure. An optional 81-byte pattern
   uses 1 for a given and 0 for an empty cell. All buffers and context must
   remain live until return. cancel is queried synchronously on the calling thread. */
typedef uint8_t (*HodokuGenerationCancelled)(void *context);
int32_t hodoku_generate_clues_v1(int64_t seed, uint8_t symmetric,
    const uint8_t *pattern, size_t pattern_len, uint32_t max_grid_attempts,
    HodokuGenerationCancelled cancel, void *context, uint8_t *clues, size_t clues_len);

#ifdef __cplusplus
}
#endif
#endif
