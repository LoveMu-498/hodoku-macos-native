/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef HODOKU_REPLAY_H
#define HODOKU_REPLAY_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint8_t value, fixed;
    uint16_t candidates, user_candidates;
} HodokuReplayCell;
/* Compare two complete, row-major replay snapshots. -1 invalid, 0 different
   givens, 1 same givens, 2 identical including both sets of pencil marks. */
int32_t hodoku_replay_relation_v1(const HodokuReplayCell *left, size_t left_len,
                                  const HodokuReplayCell *right, size_t right_len);
#ifdef __cplusplus
}
#endif
#endif
