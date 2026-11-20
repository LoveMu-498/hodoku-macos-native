// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from SimpleSolver and Sudoku2 (C) 2008–12 Bernhard Hobiger.
use super::Step;
use crate::board::{digits, houses, Board, Singles};
use crate::hints::{intersection, UNITS};
use std::ops::Deref;

#[derive(Clone)]
pub struct BasicState {
    board: Board,
    pending: Singles,
}

impl Deref for BasicState {
    type Target = Board;
    fn deref(&self) -> &Board {
        &self.board
    }
}

impl BasicState {
    /// A validated mid-game snapshot has Java's rebuilt queues.
    pub fn new(values: &[u8; 81], masks: &[u16; 81]) -> Self {
        let mut board = Board::empty();
        board.values = *values;
        let pending = board.rebuild(masks);
        Self { board, pending }
    }

    /// The Java generator inserts givens in cell order and retains the resulting queues.
    pub fn from_clues(values: &[u8; 81]) -> Self {
        let mut board = Board::empty();
        let mut pending = Singles::default();
        for (c, &d) in values.iter().enumerate().filter(|(_, d)| **d != 0) {
            board.place(c, d, &mut pending);
        }
        Self { board, pending }
    }

    pub fn first(&mut self, technique: &str) -> Option<Step> {
        match technique {
            "FULL_HOUSE" => self.pending.naked.iter().find_map(|&(c, d)| {
                if self.values[c] != 0 {
                    return None;
                }
                let bit = 1 << (d - 1);
                houses(c)
                    .into_iter()
                    .find(|&h| UNITS[h].iter().all(|&i| self.masks[i] & !bit == 0))
                    .map(|h| placement("FULL_HOUSE", c, d, Some(h as u8)))
            }),
            "NAKED_SINGLE" => {
                while let Some((c, d)) = self.pending.naked.pop_front() {
                    if self.values[c] == 0 {
                        return Some(placement("NAKED_SINGLE", c, d, None));
                    }
                }
                None
            }
            "HIDDEN_SINGLE" => {
                while let Some((c, d)) = self.pending.hidden.pop_front() {
                    if self.values[c] == 0 {
                        let bit = 1 << (d - 1);
                        return houses(c)
                            .into_iter()
                            .find(|&h| {
                                UNITS[h]
                                    .iter()
                                    .filter(|&&i| self.masks[i] & bit != 0)
                                    .count()
                                    == 1
                            })
                            .map(|h| placement("HIDDEN_SINGLE", c, d, Some(h as u8)));
                    }
                }
                None
            }
            "LOCKED_CANDIDATES_1" | "LOCKED_CANDIDATES_2" => {
                let pointing = technique == "LOCKED_CANDIDATES_1";
                let hit = intersection(&self.board, pointing, |_| true)?;
                Some(intersection_step(&hit, pointing))
            }
            "LOCKED_PAIR" => self.subset("LOCKED_PAIR", 2, false, true),
            "LOCKED_TRIPLE" => self.subset("LOCKED_TRIPLE", 3, false, true),
            "NAKED_PAIR" => self.subset("NAKED_PAIR", 2, false, false),
            "NAKED_TRIPLE" => self.subset("NAKED_TRIPLE", 3, false, false),
            "NAKED_QUADRUPLE" => self.subset("NAKED_QUADRUPLE", 4, false, false),
            "HIDDEN_PAIR" => self.subset("HIDDEN_PAIR", 2, true, false),
            "HIDDEN_TRIPLE" => self.subset("HIDDEN_TRIPLE", 3, true, false),
            "HIDDEN_QUADRUPLE" => self.subset("HIDDEN_QUADRUPLE", 4, true, false),
            _ => None,
        }
    }

    fn subset(&self, kind: &'static str, n: usize, hidden: bool, locked: bool) -> Option<Step> {
        self.visit_subsets(n, hidden, locked, &mut |step| {
            (step.kind == kind).then_some(step)
        })
    }

    fn visit_subsets(
        &self,
        n: usize,
        hidden: bool,
        blocks_only: bool,
        accept: &mut impl FnMut(Step) -> Option<Step>,
    ) -> Option<Step> {
        for house in (18..27).chain(0..if blocks_only { 0 } else { 18 }) {
            let unit = &UNITS[house];
            let mut masks = [0u16; 9];
            if hidden {
                if unit.iter().filter(|&&c| self.masks[c] != 0).count() <= n {
                    continue;
                }
                for (pos, &cell) in unit.iter().enumerate() {
                    for d in digits(self.masks[cell]) {
                        masks[d as usize - 1] |= 1 << pos;
                    }
                }
            } else {
                for (pos, &cell) in unit.iter().enumerate() {
                    masks[pos] = self.masks[cell];
                }
            }
            // Java nests loops lexicographically by ascending cell (naked) or digit (hidden).
            let mut selected = [0usize; 4];
            let found = combinations(&masks, n, &mut selected, 0, 0, 0, &mut |items, union| {
                let bits = items.iter().fold(0, |acc, &i| acc | (1u16 << i));
                let (positions, digit_mask) = if hidden { (union, bits) } else { (bits, union) };
                let cells: Vec<_> = digits(positions)
                    .map(|i| unit[i as usize - 1] as u8)
                    .collect();
                let mut deletes = Vec::new();
                let mut is_locked = false;
                if hidden {
                    for &c in &cells {
                        deletes
                            .extend(digits(self.masks[c as usize] & !digit_mask).map(|d| (c, d)));
                    }
                } else {
                    let first = houses(cells[0] as usize);
                    let mut active = 0;
                    for (axis, &h) in first.iter().enumerate() {
                        if !cells.iter().all(|&c| houses(c as usize)[axis] == h) {
                            continue;
                        }
                        let mut outside = false;
                        for &c in &UNITS[h] {
                            if cells.contains(&(c as u8)) {
                                continue;
                            }
                            let erased = self.masks[c] & digit_mask;
                            if erased == 0 {
                                continue;
                            }
                            outside |= axis == 2 || houses(c)[2] != first[2];
                            deletes.extend(digits(erased).map(|d| (c as u8, d)));
                        }
                        active += usize::from(outside);
                    }
                    is_locked = n < 4
                        && active > 1
                        && cells.iter().all(|&c| houses(c as usize)[2] == first[2]);
                }
                if deletes.is_empty() {
                    return None;
                }
                let kind = match (hidden, is_locked, n) {
                    (true, _, 2) => "HIDDEN_PAIR",
                    (true, _, 3) => "HIDDEN_TRIPLE",
                    (true, _, _) => "HIDDEN_QUADRUPLE",
                    (_, true, 2) => "LOCKED_PAIR",
                    (_, true, _) => "LOCKED_TRIPLE",
                    (_, _, 2) => "NAKED_PAIR",
                    (_, _, 3) => "NAKED_TRIPLE",
                    (_, _, _) => "NAKED_QUADRUPLE",
                };
                accept(Step {
                    kind,
                    indices: cells,
                    values: digits(digit_mask).collect(),
                    deletes,
                    house: Some(house as u8),
                    ..Step::default()
                })
            });
            if found.is_some() {
                return found;
            }
        }
        None
    }

    /// Java sorts the whole family before filtering a named technique.
    pub fn catalogue(&self, kind: &str) -> Vec<Step> {
        use crate::hints::catalogue_order::ordered_runs;
        let mut steps = Vec::new();
        match kind {
            "FULL_HOUSE" => {
                for &(c, d) in &self.pending.naked {
                    if self.values[c] != 0 {
                        continue;
                    }
                    if let Some(h) = houses(c)
                        .into_iter()
                        .find(|&h| UNITS[h].iter().all(|&i| self.masks[i] & !bit(d) == 0))
                    {
                        steps.push(placement("FULL_HOUSE", c, d, Some(h as u8)));
                    }
                }
            }
            "LOCKED_CANDIDATES_1" | "LOCKED_CANDIDATES_2" => {
                for pointing in [true, false] {
                    intersection(&self.board, pointing, |hit| {
                        steps.push(intersection_step(hit, pointing));
                        false
                    });
                }
            }
            "NAKED_SINGLE" | "HIDDEN_SINGLE" | "LOCKED_PAIR" | "LOCKED_TRIPLE" | "NAKED_PAIR"
            | "NAKED_TRIPLE" | "NAKED_QUADRUPLE" | "HIDDEN_PAIR" | "HIDDEN_TRIPLE"
            | "HIDDEN_QUADRUPLE" => {
                let hidden = kind.starts_with("HIDDEN");
                if hidden {
                    let mut seen = [false; 81];
                    for &(c, d) in &self.pending.hidden {
                        if self.values[c] != 0 || seen[c] {
                            continue;
                        }
                        if let Some(h) = houses(c).into_iter().find(|&h| {
                            UNITS[h]
                                .iter()
                                .filter(|&&i| self.masks[i] & bit(d) != 0)
                                .count()
                                == 1
                        }) {
                            seen[c] = true;
                            steps.push(placement("HIDDEN_SINGLE", c, d, Some(h as u8)));
                        }
                    }
                } else {
                    for &(c, d) in &self.pending.naked {
                        if self.values[c] == 0 {
                            steps.push(placement("NAKED_SINGLE", c, d, None));
                        }
                    }
                }
                if kind.ends_with("SINGLE") {
                    return ordered_runs(&steps)
                        .into_iter()
                        .map(|i| steps[i].clone())
                        .collect();
                }
                steps = ordered_runs(&steps)
                    .into_iter()
                    .map(|i| steps[i].clone())
                    .collect();
                for n in 2..=4 {
                    self.visit_subsets(n, hidden, false, &mut |step| {
                        steps.push(step);
                        None
                    });
                }
            }
            _ => return steps,
        }
        ordered_runs(&steps)
            .into_iter()
            .filter(|&i| steps[i].kind == kind)
            .map(|i| steps[i].clone())
            .collect()
    }

    pub(super) fn assume(&mut self, cell: usize, digit: u8, on: bool) {
        if on {
            if self.values[cell] != digit {
                self.board.place(cell, digit, &mut self.pending);
            }
        } else {
            self.board.delete(cell, digit, &mut self.pending);
        }
    }

    /// Apply Java's ordered deletions (including harmless duplicates) to the same queues.
    pub fn apply(&mut self, step: &Step) -> bool {
        let mut board = self.board.clone();
        let mut pending = self.pending.clone();
        if !step.deletes.is_empty() {
            for &(c, d) in &step.deletes {
                if c >= 81 || !(1..=9).contains(&d) || self.masks[c as usize] & bit(d) == 0 {
                    return false;
                }
                // Sudoku2.delCandidate can mark a contradiction after removing the digit.
                // Java doStep still executes all remaining eliminations in their given order.
                board.delete(c as usize, d, &mut pending);
            }
        } else {
            let broadcast = step.kind == "TEMPLATE_SET" && step.values.len() == 1;
            if step.indices.is_empty() || (!broadcast && step.indices.len() != step.values.len()) {
                return false;
            }
            for (i, &c) in step.indices.iter().enumerate() {
                let d = step.values[if broadcast { 0 } else { i }];
                if c >= 81
                    || !(1..=9).contains(&d)
                    || board.values[c as usize] != 0
                    || board.masks[c as usize] & bit(d) == 0
                    || !board.place(c as usize, d, &mut pending)
                {
                    return false;
                }
            }
        }
        self.board = board;
        self.pending = pending;
        true
    }
}

fn intersection_step(hit: &crate::hints::HintStep, pointing: bool) -> Step {
    let d = hit.digits.trailing_zeros() as u8 + 1;
    Step {
        kind: if pointing {
            "LOCKED_CANDIDATES_1"
        } else {
            "LOCKED_CANDIDATES_2"
        },
        house: Some(hit.house),
        indices: hit.premises[..hit.premise_count as usize].to_vec(),
        values: vec![d],
        deletes: hit
            .deletions
            .iter()
            .enumerate()
            .filter(|(_, m)| **m != 0)
            .map(|(c, _)| (c as u8, d))
            .collect(),
        ..Step::default()
    }
}

fn placement(kind: &'static str, cell: usize, digit: u8, house: Option<u8>) -> Step {
    Step {
        kind,
        indices: vec![cell as u8],
        values: vec![digit],
        house,
        ..Step::default()
    }
}

fn combinations(
    masks: &[u16; 9],
    n: usize,
    selected: &mut [usize; 4],
    pos: usize,
    start: usize,
    union: u16,
    visit: &mut impl FnMut(&[usize], u16) -> Option<Step>,
) -> Option<Step> {
    if pos == n {
        return if union.count_ones() as usize == n {
            visit(&selected[..n], union)
        } else {
            None
        };
    }
    for i in start..=9 - (n - pos) {
        let next = union | masks[i];
        if masks[i] == 0 || next.count_ones() as usize > n {
            continue;
        }
        selected[pos] = i;
        if let Some(s) = combinations(masks, n, selected, pos + 1, i + 1, next, visit) {
            return Some(s);
        }
    }
    None
}

fn bit(digit: u8) -> u16 {
    1 << (digit - 1)
}

impl crate::hints::catalogue_order::CatalogueOrder for Step {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        use std::cmp::Ordering;
        let comparison = other
            .deletes
            .is_empty()
            .cmp(&self.deletes.is_empty())
            .then_with(|| other.deletes.len().cmp(&self.deletes.len()));
        if comparison != Ordering::Equal {
            return comparison;
        }
        let equivalent = self.kind == other.kind
            && if self.deletes.is_empty() {
                self.indices == other.indices
            } else {
                self.deletes.iter().all(|pair| other.deletes.contains(pair))
            };
        if !equivalent {
            let weight = |s: &Step| {
                s.deletes
                    .iter()
                    .enumerate()
                    .map(|(i, &(c, d))| usize::from(c) * (1 + i * 80) + usize::from(d))
                    .sum::<usize>()
            };
            return weight(self).cmp(&weight(other));
        }
        let sum = |list: &[u8]| list.iter().copied().map(usize::from).sum::<usize>();
        if self.values != other.values {
            return sum(&self.values).cmp(&sum(&other.values));
        }
        self.indices
            .len()
            .cmp(&other.indices.len())
            .then_with(|| sum(&other.indices).cmp(&sum(&self.indices)))
    }
}
