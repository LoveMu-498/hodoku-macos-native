/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HODOKU_CHAIN_H
#define HODOKU_CHAIN_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Receives one contradiction path per selected conclusion. A literal is 2*node
   for false, 2*node+1 for true. node_count denotes the external target.
   This callback and all borrowed buffers expire before analyze returns. */
typedef void (*HodokuChainProof)(void *context, uint16_t target, const size_t *literals, size_t count);
typedef struct {
    uint8_t status; /* 0 incomplete, 1 invalid, 2 no conclusion, 3 proven, 4 assumed */
    uint8_t placement_cell; /* 255 = no placement */
    uint8_t placement_digit;
    uint16_t deletions[81];
} HodokuChainResult;
/* offsets has one more item than the number of nodes. Each node's range of
   sorted, unique atoms (cell*10+digit) is nonempty. Relations: 1 strong, 0 weak.
   0 success, 1 malformed board/input, 2 engine error. All buffers borrowed. */
int32_t hodoku_analyze_chain_v1(const uint8_t *values, size_t value_count, const uint16_t *masks, size_t mask_count,
    const uint16_t *atoms, size_t atom_count, const size_t *offsets, size_t offset_count,
    const uint8_t *edges, size_t edge_count, uint8_t closed,
    HodokuChainProof proof, void *context, HodokuChainResult *out);
/* A non-null batch receives ordinary candidate masks for ALL authored conclusions.
   The selected step, path callbacks, status and input contract are identical to v1. */
typedef struct {
    uint16_t truths[81];
    uint16_t falses[81];
} HodokuChainConclusions;
int32_t hodoku_analyze_chain_v2(const uint8_t *values, size_t value_count, const uint16_t *masks, size_t mask_count,
    const uint16_t *atoms, size_t atom_count, const size_t *offsets, size_t offset_count,
    const uint8_t *edges, size_t edge_count, uint8_t closed,
    HodokuChainProof proof, void *context, HodokuChainResult *out, HodokuChainConclusions *batch);
#ifdef __cplusplus
}
#endif
#endif
