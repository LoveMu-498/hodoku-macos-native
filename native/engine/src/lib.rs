// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2008-12 Bernhard Hobiger.
// Bounded search adapted from SudokuGenerator.java (Bernhard Hobiger,
// based on the solver posted by Glenn Fowler in the Sudoku Player's Forum).
mod board;
pub mod chain;
mod chain_ffi;
mod ffi;
pub mod hints;
pub mod phase5;
pub mod replay_board;

use board::{digits, Board, Singles};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidInput;

#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Termination {
    Exhausted,
    SolutionBound,
    Limit,
    Cancelled,
}

#[derive(Debug, PartialEq, Eq)]
pub struct CountResult {
    pub termination: Termination,
    pub count: u32,
    pub tries: u32,
    pub solution: Option<[u8; 81]>,
}

struct Search<'a> {
    max_solutions: u32,
    max_tries: u32,
    cancelled: &'a dyn Fn() -> bool,
    count: u32,
    tries: u32,
    first: Option<[u8; 81]>,
    has_empty_domain: bool,
}

impl Search<'_> {
    fn limit(&self) -> Option<Termination> {
        if (self.cancelled)() {
            Some(Termination::Cancelled)
        } else if self.tries >= self.max_tries {
            Some(Termination::Limit)
        } else {
            None
        }
    }
    fn solved(&mut self, board: &Board) -> Option<Termination> {
        self.count += 1;
        if self.count == 1 {
            self.first = Some(board.values);
        } else if self.count > self.max_solutions {
            return Some(Termination::SolutionBound);
        }
        None
    }
    // None means this subtree is exhausted. Only a stop reason aborts its siblings.
    fn visit(&mut self, board: &Board) -> Option<Termination> {
        if let Some(reason) = self.limit() {
            return Some(reason);
        }
        if board.remaining == 0 {
            return self.solved(board);
        }
        let cell = board
            .masks
            .iter()
            .enumerate()
            .filter(|(_, mask)| **mask != 0)
            .min_by_key(|(_, mask)| mask.count_ones());
        // A zero domain can already be present in an edited snapshot. Java
        // checks the budget first and stops once no selectable cell remains.
        // Nine-way choices are needed for the valid, wholly unconstrained grid.
        let Some((cell, &mask)) = cell else {
            return Some(Termination::Exhausted);
        };
        if mask.count_ones() == 9 && self.has_empty_domain {
            return Some(Termination::Exhausted);
        }
        for digit in digits(mask) {
            if let Some(reason) = self.limit() {
                return Some(reason);
            }
            self.tries += 1;
            let mut next = board.clone();
            let mut pending = Singles::default();
            if next.place(cell, digit, &mut pending) && next.propagate(&mut pending) {
                if let Some(reason) = self.visit(&next) {
                    return Some(reason);
                }
            }
        }
        None
    }
}

/// Counts ordinary candidate-constrained completions. Only an exhausted single
/// solution carries its witness. All search state is private to the call.
pub fn count_solutions(
    values: &[u8; 81],
    candidates: Option<&[u16; 81]>,
    max_solutions: u32,
    max_tries: u32,
    cancelled: &dyn Fn() -> bool,
) -> Result<CountResult, InvalidInput> {
    let (mut board, mut pending) = Board::from_snapshot(values, candidates)?;
    let mut search = Search {
        max_solutions,
        max_tries,
        cancelled,
        count: 0,
        tries: 0,
        first: None,
        has_empty_domain: board
            .values
            .iter()
            .zip(&board.masks)
            .any(|(&v, &m)| v == 0 && m == 0),
    };
    let termination = if cancelled() {
        Termination::Cancelled
    } else {
        let possible = board.propagate(&mut pending);
        if cancelled() {
            Termination::Cancelled
        } else if !possible {
            Termination::Exhausted
        } else if board.remaining == 0 {
            search.solved(&board);
            Termination::Exhausted
        } else {
            search.visit(&board).unwrap_or(Termination::Exhausted)
        }
    };
    Ok(CountResult {
        termination,
        count: search.count,
        tries: search.tries,
        solution: if termination == Termination::Exhausted && search.count == 1 {
            search.first
        } else {
            None
        },
    })
}
