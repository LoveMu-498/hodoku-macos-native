// SPDX-License-Identifier: GPL-3.0-or-later
//! ReplayBoard.java validates representation while preserving incorrect historical moves.
#[repr(C)]
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct ReplayCell {
    pub value: u8,
    pub fixed: u8,
    pub candidates: u16,
    pub user_candidates: u16,
}

fn valid(board: &[ReplayCell]) -> bool {
    board.len() == 81
        && board.iter().all(|c| {
            c.value <= 9
                && c.fixed <= 1
                && (c.fixed == 0 || c.value != 0)
                && c.candidates <= 511
                && c.user_candidates <= 511
                && (c.value == 0 || c.candidates == 0)
        })
}

pub fn relation(left: &[ReplayCell], right: &[ReplayCell]) -> i32 {
    if !valid(left) || !valid(right) {
        return -1;
    }
    if left == right {
        return 2;
    }
    let same = left
        .iter()
        .zip(right)
        .all(|(a, b)| a.fixed == b.fixed && (a.fixed == 0 || a.value == b.value));
    i32::from(same)
}

/// # Safety
/// Each non-null pointer must refer to its indicated number of initialized cells.
#[no_mangle]
pub unsafe extern "C" fn hodoku_replay_relation_v1(
    left: *const ReplayCell,
    left_len: usize,
    right: *const ReplayCell,
    right_len: usize,
) -> i32 {
    if left.is_null() || right.is_null() || left_len != 81 || right_len != 81 {
        return -1;
    }
    relation(
        std::slice::from_raw_parts(left, left_len),
        std::slice::from_raw_parts(right, right_len),
    )
}
