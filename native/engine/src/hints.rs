// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from SimpleSolver.java, Copyright (C) 2008-12 Bernhard Hobiger.
use crate::board::{houses, Board};
use crate::InvalidInput;
pub(crate) mod catalogue_order;

#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Technique {
    None,
    FullHouse,
    NakedSingle,
    HiddenSingle,
    LockedPair,
    LockedTriple,
    Pointing,
    Claiming,
}

/// Fixed C representation. A conclusion has either one placement or one or
/// more candidate eliminations. The Rust engine never edits the submitted board.
#[repr(C)]
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HintStep {
    pub technique: Technique,
    pub house: u8,
    pub digits: u16,
    pub premise_count: u8,
    pub premises: [u8; 9],
    pub placement_cell: u8,
    pub placement_digit: u8,
    pub deletions: [u16; 81],
}

impl Default for HintStep {
    fn default() -> Self {
        Self {
            technique: Technique::None,
            house: 255,
            digits: 0,
            premise_count: 0,
            premises: [0; 9],
            placement_cell: 255,
            placement_digit: 0,
            deletions: [0; 81],
        }
    }
}

impl HintStep {
    fn single(technique: Technique, cell: usize, digit: u8, house: Option<usize>) -> Self {
        let mut result = Self {
            technique,
            digits: 1 << (digit - 1),
            house: house.map_or(255, |h| h as u8),
            placement_cell: cell as u8,
            placement_digit: digit,
            ..Self::default()
        };
        result.add_premise(cell);
        result
    }

    fn add_premise(&mut self, cell: usize) {
        self.premises[self.premise_count as usize] = cell as u8;
        self.premise_count += 1;
    }
}

const fn units() -> [[usize; 9]; 27] {
    let mut table = [[0; 9]; 27];
    let mut i = 0;
    while i < 81 {
        table[i / 9][i % 9] = i;
        table[9 + i % 9][i / 9] = i;
        table[18 + i / 27 * 3 + i % 9 / 3][i / 9 % 3 * 3 + i % 3] = i;
        i += 1;
    }
    table
}
pub(crate) const UNITS: [[usize; 9]; 27] = units();

// Java rebuilds naked singles by cell and hidden singles by unit, then digit.
fn visit_singles(
    board: &Board,
    technique: Technique,
    mut take: impl FnMut(&HintStep) -> bool,
) -> Option<HintStep> {
    if technique == Technique::HiddenSingle {
        let mut seen = [false; 81];
        for (house, unit) in UNITS.iter().enumerate() {
            for digit in 1..=9 {
                let mut cells = unit
                    .iter()
                    .copied()
                    .filter(|&c| board.masks[c] & (1 << (digit - 1)) != 0);
                if let Some(cell) = cells.next() {
                    if cells.next().is_none() && !seen[cell] {
                        seen[cell] = true;
                        let step = HintStep::single(technique, cell, digit, Some(house));
                        if take(&step) {
                            return Some(step);
                        }
                    }
                }
            }
        }
    } else {
        for (cell, &mask) in board
            .masks
            .iter()
            .enumerate()
            .filter(|(_, m)| m.count_ones() == 1)
        {
            let house = if technique == Technique::FullHouse {
                let Some(h) = houses(cell)
                    .into_iter()
                    .find(|&h| UNITS[h].iter().all(|&c| board.masks[c] & !mask == 0))
                else {
                    continue;
                };
                Some(h)
            } else {
                None
            };
            let step = HintStep::single(technique, cell, mask.trailing_zeros() as u8 + 1, house);
            if take(&step) {
                return Some(step);
            }
        }
    }
    None
}

fn singles(board: &Board, selected: Option<usize>) -> Option<HintStep> {
    let mut eligible = |s: &HintStep| selected.is_none_or(|c| c == usize::from(s.placement_cell));
    if selected.is_none() {
        if let Some(s) = visit_singles(board, Technique::FullHouse, &mut eligible) {
            return Some(s);
        }
    }
    visit_singles(board, Technique::NakedSingle, &mut eligible)
        .or_else(|| visit_singles(board, Technique::HiddenSingle, eligible))
}

fn locked_subset(board: &Board, cells: &[usize], block: usize) -> Option<HintStep> {
    let digits = cells.iter().fold(0, |m, &c| m | board.masks[c]);
    if digits.count_ones() as usize != cells.len() {
        return None;
    }
    let first = houses(cells[0]);
    let line = (0..2).find(|&axis| cells.iter().all(|&c| houses(c)[axis] == first[axis]))?;
    let mut step = HintStep {
        technique: if cells.len() == 2 {
            Technique::LockedPair
        } else {
            Technique::LockedTriple
        },
        digits,
        house: block as u8,
        ..HintStep::default()
    };
    // Java classifies a locked subset only when the box contributes deletions
    // and the common row/column also eliminates candidates outside the box.
    let mut outside = false;
    for &c in &UNITS[first[line]] {
        if !cells.contains(&c) {
            step.deletions[c] = board.masks[c] & digits;
            outside |= houses(c)[2] != block && step.deletions[c] != 0;
        }
    }
    if !outside {
        return None;
    }
    let mut inside = false;
    for &c in &UNITS[block] {
        if !cells.contains(&c) {
            step.deletions[c] = board.masks[c] & digits;
            inside |= step.deletions[c] != 0;
        }
    }
    if !inside {
        return None;
    }
    for &cell in cells {
        step.add_premise(cell);
    }
    Some(step)
}

fn exact_cells(premises: &[u8], selection: Option<&[u8]>) -> bool {
    selection.is_none_or(|cells| {
        cells.len() == premises.len() && cells.iter().all(|c| premises.contains(c))
    })
}

fn subsets(
    board: &Board,
    size: usize,
    mut take: impl FnMut(&HintStep) -> bool,
) -> Option<HintStep> {
    for (block, unit) in UNITS.iter().enumerate().skip(18) {
        let cells: Vec<usize> = unit
            .iter()
            .copied()
            .filter(|&c| {
                let n = board.masks[c].count_ones() as usize;
                (1..=size).contains(&n)
            })
            .collect();
        for (i, &a) in cells.iter().enumerate() {
            for (j, &b) in cells.iter().enumerate().skip(i + 1) {
                if size == 2 {
                    if let Some(s) = locked_subset(board, &[a, b], block).filter(&mut take) {
                        return Some(s);
                    }
                } else {
                    for &c in &cells[j + 1..] {
                        if let Some(s) = locked_subset(board, &[a, b, c], block).filter(&mut take) {
                            return Some(s);
                        }
                    }
                }
            }
        }
    }
    None
}

pub(crate) fn intersection(
    board: &Board,
    pointing: bool,
    mut take: impl FnMut(&HintStep) -> bool,
) -> Option<HintStep> {
    let sources = if pointing { 18..27 } else { 0..18 };
    for source in sources {
        for digit in 1u8..=9 {
            let bit = 1 << (digit - 1);
            let mut step = HintStep {
                technique: if pointing {
                    Technique::Pointing
                } else {
                    Technique::Claiming
                },
                digits: bit,
                house: source as u8,
                ..HintStep::default()
            };
            for &cell in &UNITS[source] {
                if board.masks[cell] & bit != 0 {
                    step.add_premise(cell);
                }
            }
            if !(2..=3).contains(&step.premise_count) {
                continue;
            }
            let cells = &step.premises[..step.premise_count as usize];
            let axes = if pointing { 0..2 } else { 2..3 };
            let first = houses(cells[0] as usize);
            for axis in axes {
                if cells
                    .iter()
                    .all(|&c| houses(c as usize)[axis] == first[axis])
                {
                    for &c in &UNITS[first[axis]] {
                        if !cells.contains(&(c as u8)) {
                            step.deletions[c] = board.masks[c] & bit;
                        }
                    }
                    if step.deletions.iter().any(|&m| m != 0) && take(&step) {
                        return Some(step);
                    }
                }
            }
        }
    }
    None
}

pub(crate) fn checked_board(values: &[u8; 81], masks: &[u16; 81]) -> Result<Board, InvalidInput> {
    let (board, _) = Board::from_snapshot(values, Some(masks))?;
    if (0..81).any(|c| values[c] == 0 && masks[c] == 0)
        || UNITS.iter().any(|unit| {
            unit.iter().fold(0, |m, c| {
                m | if values[*c] == 0 {
                    masks[*c]
                } else {
                    1 << (values[*c] - 1)
                }
            }) != 511
        })
    {
        return Err(InvalidInput);
    }
    Ok(board)
}

fn eliminations(board: &Board, selection: Option<&[u8]>) -> Option<HintStep> {
    let matches =
        |s: &HintStep| exact_cells(&s.premises[..usize::from(s.premise_count)], selection);
    if let Some(step) = subsets(board, 2, matches).or_else(|| subsets(board, 3, matches)) {
        return Some(step);
    }
    for pointing in [true, false] {
        let mut selected = Vec::new();
        let first = intersection(board, pointing, |s| {
            if !matches(s) {
                return false;
            }
            if selection.is_none() {
                return true;
            }
            selected.push(s.clone());
            false
        });
        if let Some(s) = first.or_else(|| {
            sort_catalogue(&mut selected);
            selected.into_iter().next()
        }) {
            return Some(s);
        }
    }
    None
}

pub fn next_step(values: &[u8; 81], masks: &[u16; 81]) -> Result<HintStep, InvalidInput> {
    let board = checked_board(values, masks)?;
    Ok(singles(&board, None)
        .or_else(|| eliminations(&board, None))
        .unwrap_or_default())
}

/// Match exactly the union of the authored boxes against every supported instance.
/// A single selects its conclusion; all other supported techniques select premises.
pub fn step_for_cells(
    values: &[u8; 81],
    masks: &[u16; 81],
    selection: &[u8],
) -> Result<HintStep, InvalidInput> {
    if selection.is_empty()
        || selection.len() > 81
        || selection
            .iter()
            .enumerate()
            .any(|(i, c)| *c >= 81 || selection[..i].contains(c))
    {
        return Err(InvalidInput);
    }
    let board = checked_board(values, masks)?;
    let step = match selection {
        [c] => singles(&board, Some(*c as usize)),
        [_, _] | [_, _, _] => eliminations(&board, Some(selection)),
        _ => None,
    };
    Ok(step.unwrap_or_default())
}

/// Java SolutionStep.compareTo uses the unmerged row/column and box deletion list.
/// The exported conclusion is still canonicalized to a mask per cell.
fn java_deletion_rank(s: &HintStep) -> (std::cmp::Reverse<usize>, usize) {
    let first = usize::from(s.premises[0]);
    let hs = houses(first);
    let support = &s.premises[..usize::from(s.premise_count)];
    let mut count = 0;
    let mut weighted = 0;
    let mut add = |cell: usize| {
        for d in crate::board::digits(s.deletions[cell]) {
            weighted += cell * (1 + 80 * count) + usize::from(d);
            count += 1;
        }
    };
    if matches!(s.technique, Technique::LockedPair | Technique::LockedTriple) {
        for h in hs {
            if support.iter().all(|&c| houses(usize::from(c)).contains(&h)) {
                for &c in &UNITS[h] {
                    add(c);
                }
            }
        }
    } else {
        for c in 0..81 {
            add(c);
        }
    }
    (std::cmp::Reverse(count), weighted)
}

fn sort_catalogue(steps: &mut [HintStep]) {
    steps.sort_by(|a, b| {
        let (na, wa) = java_deletion_rank(a);
        let (nb, wb) = java_deletion_rank(b);
        na.cmp(&nb).then_with(|| {
            if a.deletions != b.deletions {
                return wa.cmp(&wb);
            }
            // Different placement cells are not equivalent. Java keeps queue order.
            if a.placement_cell != b.placement_cell {
                return std::cmp::Ordering::Equal;
            }
            let sum = |s: &HintStep| {
                crate::board::digits(s.digits)
                    .map(usize::from)
                    .sum::<usize>()
            };
            let index = |s: &HintStep| {
                s.premises[..usize::from(s.premise_count)]
                    .iter()
                    .copied()
                    .map(usize::from)
                    .sum::<usize>()
            };
            sum(a).cmp(&sum(b)).then_with(|| index(b).cmp(&index(a)))
        })
    });
}

/// All seven supported types in default technique order, with the original
/// instance order inside each type (including equal occurrences in the Java list).
pub fn catalogue(values: &[u8; 81], masks: &[u16; 81]) -> Result<Vec<HintStep>, InvalidInput> {
    let board = checked_board(values, masks)?;
    let mut list = Vec::new();
    for t in [
        Technique::FullHouse,
        Technique::NakedSingle,
        Technique::HiddenSingle,
        Technique::LockedPair,
        Technique::LockedTriple,
        Technique::Pointing,
        Technique::Claiming,
    ] {
        let mut steps = Vec::new();
        let add = |s: &HintStep| {
            steps.push(s.clone());
            false
        };
        match t {
            Technique::FullHouse | Technique::NakedSingle | Technique::HiddenSingle => {
                visit_singles(&board, t, add);
            }
            Technique::LockedPair | Technique::LockedTriple => {
                // These are sorted inside the full Java NakedXle list, together
                // with its ordinary subsets, before grouping them by technique.
                // A later per-family sort can change their displayed numbers.
                if t == Technique::LockedPair {
                    let naked = catalogue_order::locked_instances(&board);
                    list.extend(
                        naked
                            .iter()
                            .filter(|s| s.technique == Technique::LockedPair)
                            .cloned(),
                    );
                    list.extend(
                        naked
                            .into_iter()
                            .filter(|s| s.technique == Technique::LockedTriple),
                    );
                }
                continue;
            }
            _ => {
                intersection(&board, t == Technique::Pointing, add);
            }
        }
        sort_catalogue(&mut steps);
        list.extend(steps);
    }
    Ok(list)
}
