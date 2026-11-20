// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from SudokuGenerator.java, Copyright (C) 2008-12 Bernhard Hobiger.
use crate::board::{digits, Board, Singles};
use crate::{count_solutions, Termination};

/// java.util.Random's 48-bit state and bounded nextInt, for reproducible Java comparisons.
struct Random(u64);

impl Random {
    const MULT: u64 = 0x5deece66d;
    const MASK: u64 = (1 << 48) - 1;
    fn new(seed: i64) -> Self {
        Self((seed as u64 ^ Self::MULT) & Self::MASK)
    }
    fn cell(&mut self) -> usize {
        loop {
            self.0 = self.0.wrapping_mul(Self::MULT).wrapping_add(11) & Self::MASK;
            let bits = (self.0 >> 17) as i32;
            let index = bits % 81;
            if (bits - index).checked_add(80).is_some() {
                return index as usize;
            }
        }
    }
    fn cell_order(&mut self) -> [usize; 81] {
        let mut order = std::array::from_fn(|index| index);
        for _ in 0..81 {
            let left = self.cell();
            let mut right = self.cell();
            while left == right {
                right = self.cell();
            }
            order.swap(left, right);
        }
        order
    }
}

#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GenerationStop {
    Cancelled = 1,
    SearchLimit = 2,
    PatternRejected = 3,
}

/// Java restarts with another randomized cell order after 100 expansions. Hitting
/// this local bound abandons the entire order, not only the deepest branch.
fn fill(
    board: &Board,
    order: &[usize; 81],
    expansions: &mut u32,
    cancelled: &dyn Fn() -> bool,
) -> Result<Option<[u8; 81]>, GenerationStop> {
    if cancelled() {
        return Err(GenerationStop::Cancelled);
    }
    let Some(&cell) = order.iter().find(|&&i| board.values[i] == 0) else {
        return Ok(Some(board.values));
    };
    *expansions += 1;
    if *expansions > 100 {
        return Err(GenerationStop::SearchLimit);
    }
    for digit in digits(board.masks[cell]) {
        let mut next = board.clone();
        let mut singles = Singles::default();
        if next.place(cell, digit, &mut singles) && next.propagate(&mut singles) {
            if let Some(full) = fill(&next, order, expansions, cancelled)? {
                return Ok(Some(full));
            }
        }
    }
    Ok(None)
}

fn unique(clues: &[u8; 81], cancelled: &dyn Fn() -> bool) -> Result<bool, GenerationStop> {
    let result = count_solutions(clues, None, 1, 1_000_000, cancelled)
        .map_err(|_| GenerationStop::PatternRejected)?;
    match result.termination {
        Termination::Cancelled => Err(GenerationStop::Cancelled),
        Termination::Exhausted => Ok(result.count == 1),
        Termination::Limit => Err(GenerationStop::SearchLimit),
        Termination::SolutionBound => Ok(false),
    }
}

/// Generate one candidate with Java's full-grid search, symmetry and clue-removal order.
/// The caller rates it according to its game mode. Seeds are testable, not a puzzle list.
pub fn generate_clues(
    seed: i64,
    symmetric: bool,
    pattern: Option<&[u8; 81]>,
    max_grid_attempts: u32,
    cancelled: &dyn Fn() -> bool,
) -> Result<[u8; 81], GenerationStop> {
    if cancelled() {
        return Err(GenerationStop::Cancelled);
    }
    let mut rng = Random::new(seed);
    let (empty, _) =
        Board::from_snapshot(&[0; 81], None).map_err(|_| GenerationStop::SearchLimit)?;
    let mut solution = None;
    for _ in 0..max_grid_attempts {
        match fill(&empty, &rng.cell_order(), &mut 0, cancelled) {
            Ok(Some(full)) => {
                solution = Some(full);
                break;
            }
            Ok(None) | Err(GenerationStop::SearchLimit) => continue,
            Err(stop) => return Err(stop),
        }
    }
    let full = solution.ok_or(GenerationStop::SearchLimit)?;
    if let Some(pattern) = pattern {
        if pattern.iter().any(|&cell| cell > 1) {
            return Err(GenerationStop::PatternRejected);
        }
        let clues = std::array::from_fn(|i| if pattern[i] == 1 { full[i] } else { 0 });
        // Java retries the same full grid and mask without advancing the RNG.
        // A second search could not change this answer.
        return if unique(&clues, cancelled)? {
            Ok(clues)
        } else {
            Err(GenerationStop::PatternRejected)
        };
    }
    let mut clues = full;
    let mut used = [false; 81];
    let mut positions_left = 81;
    let mut clues_left = 81;
    while clues_left > 17 && positions_left > 1 {
        if cancelled() {
            return Err(GenerationStop::Cancelled);
        }
        let mut cell = (rng.cell() + 1) % 81;
        while used[cell] {
            cell = (cell + 1) % 81;
        }
        used[cell] = true;
        positions_left -= 1;
        let opposite = if symmetric { 80 - cell } else { cell };
        if clues[cell] == 0 || clues[opposite] == 0 {
            continue;
        }
        clues[cell] = 0;
        clues_left -= 1;
        if opposite != cell {
            clues[opposite] = 0;
            used[opposite] = true;
            positions_left -= 1;
            clues_left -= 1;
        }
        // An unproven removal is discarded. The previously accepted puzzle
        // remains certified even when this trial reaches the search cap.
        let remove = match unique(&clues, cancelled) {
            Ok(confirmed) => confirmed,
            Err(GenerationStop::SearchLimit) => false,
            Err(stop) => return Err(stop),
        };
        if !remove {
            clues[cell] = full[cell];
            clues_left += 1;
            if opposite != cell {
                clues[opposite] = full[opposite];
                clues_left += 1;
            }
        }
    }
    Ok(clues)
}

type CancelQuery = extern "C" fn(*mut std::ffi::c_void) -> u8;

/// # Safety
/// All non-null pointers obey HodokuGeneration.h. No pointer or callback is retained.
#[no_mangle]
pub unsafe extern "C" fn hodoku_generate_clues_v1(
    seed: i64,
    symmetric: u8,
    pattern: *const u8,
    pattern_len: usize,
    max_grid_attempts: u32,
    cancel: Option<CancelQuery>,
    context: *mut std::ffi::c_void,
    clues: *mut u8,
    clues_len: usize,
) -> i32 {
    if clues.is_null()
        || clues_len != 81
        || symmetric > 1
        || !matches!((pattern.is_null(), pattern_len), (true, 0) | (false, 81))
    {
        return 4;
    }
    std::panic::catch_unwind(|| {
        // SAFETY: a non-null pattern borrows the declared 81 bytes for this invocation.
        let mask = unsafe { pattern.cast::<[u8; 81]>().as_ref() };
        match generate_clues(seed, symmetric == 1, mask, max_grid_attempts, &|| {
            cancel.is_some_and(|query| query(context) != 0)
        }) {
            Ok(result) => {
                // SAFETY: caller supplies space for 81 bytes, disjoint from input.
                unsafe { clues.cast::<[u8; 81]>().write(result) };
                0
            }
            Err(reason) => reason as i32,
        }
    })
    .unwrap_or(5)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bounds_and_cancellation_do_not_publish_puzzles() {
        assert_eq!(
            generate_clues(17, true, None, 0, &|| false),
            Err(GenerationStop::SearchLimit)
        );
        assert_eq!(
            generate_clues(17, true, None, 0, &|| true),
            Err(GenerationStop::Cancelled)
        );
        let calls = std::cell::Cell::new(0usize);
        let cancel = || {
            calls.set(calls.get() + 1);
            calls.get() > 25
        };
        assert_eq!(
            generate_clues(17, true, None, 100, &cancel),
            Err(GenerationStop::Cancelled)
        );
        assert_eq!(
            generate_clues(17, true, Some(&[0; 81]), 100, &|| false),
            Err(GenerationStop::PatternRejected)
        );
    }
}
