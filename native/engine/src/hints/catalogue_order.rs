// SPDX-License-Identifier: GPL-3.0-or-later
// Comparator metadata for SimpleSolver.findAllNakedXle and SolutionStep.compareTo.
use super::{houses, locked_subset, Board, HintStep, UNITS};
use crate::board::digits;
use std::cmp::Ordering;

#[derive(Clone)]
struct SortEntry {
    cells: Vec<usize>,
    digits: u16,
    // Java preserves duplicates shared by the line and the box.
    raw: Vec<(usize, u8)>,
    weight: usize,
    locked: Option<HintStep>,
}

impl SortEntry {
    fn from_cells(board: &Board, cells: &[usize], mask: u16) -> Option<Self> {
        let hs = houses(cells[0]);
        let mut raw = Vec::new();
        for h in hs {
            if cells.iter().all(|&c| houses(c).contains(&h)) {
                for &c in &UNITS[h] {
                    if !cells.contains(&c) {
                        raw.extend(digits(board.masks[c] & mask).map(|d| (c, d)));
                    }
                }
            }
        }
        if raw.is_empty() {
            return None;
        }
        let weight = raw
            .iter()
            .enumerate()
            .map(|(i, (c, d))| c * (1 + 80 * i) + usize::from(*d))
            .sum();
        let locked = if cells.len() < 4 && cells.iter().all(|&c| houses(c)[2] == hs[2]) {
            locked_subset(board, cells, hs[2])
        } else {
            None
        };
        Some(Self {
            cells: cells.to_vec(),
            digits: mask,
            raw,
            weight,
            locked,
        })
    }

    fn cmp(&self, other: &Self) -> Ordering {
        let placements = self.raw.is_empty();
        if placements || other.raw.is_empty() {
            return other.raw.is_empty().cmp(&placements);
        }
        let by_count = other.raw.len().cmp(&self.raw.len());
        if by_count != Ordering::Equal {
            return by_count;
        }
        let same_type = self.cells.len() == other.cells.len()
            && self.locked.is_some() == other.locked.is_some();
        if !same_type || !self.raw.iter().all(|c| other.raw.contains(c)) {
            return self.weight.cmp(&other.weight);
        }
        if self.digits != other.digits {
            let digit_sum = |m| digits(m).map(usize::from).sum::<usize>();
            return digit_sum(self.digits).cmp(&digit_sum(other.digits));
        }
        other
            .cells
            .iter()
            .sum::<usize>()
            .cmp(&self.cells.iter().sum())
    }
}

fn combinations(
    board: &Board,
    cells: &[usize],
    size: usize,
    selected: &mut Vec<usize>,
    mask: u16,
    entries: &mut Vec<SortEntry>,
) {
    if selected.len() == size {
        if mask.count_ones() as usize == size {
            if let Some(s) = SortEntry::from_cells(board, selected, mask) {
                entries.push(s);
            }
        }
        return;
    }
    for (i, &c) in cells.iter().enumerate() {
        if cells.len() - i < size - selected.len() {
            break;
        }
        let combined = mask | board.masks[c];
        if combined.count_ones() as usize > size {
            continue;
        }
        selected.push(c);
        combinations(board, &cells[i + 1..], size, selected, combined, entries);
        selected.pop();
    }
}

/// Build ascending runs before merging, as Java does. In this legacy comparator
/// equal eliminations use premise order, and unequal eliminations use a weighted
/// index sum. Those choices can be non-transitive; the input runs matter.
pub(crate) trait CatalogueOrder {
    fn cmp(&self, other: &Self) -> Ordering;
}

impl CatalogueOrder for SortEntry {
    fn cmp(&self, other: &Self) -> Ordering {
        self.cmp(other)
    }
}

pub(crate) fn ordered_runs(entries: &[impl CatalogueOrder]) -> Vec<usize> {
    let mut minimum = entries.len();
    let mut extra = 0;
    while minimum >= 32 {
        extra |= minimum & 1;
        minimum >>= 1
    }
    minimum += extra;
    let mut runs: Vec<Vec<usize>> = Vec::new();
    let mut start = 0;
    while start < entries.len() {
        let mut end = start + 1;
        let descending = end < entries.len() && entries[end].cmp(&entries[start]) == Ordering::Less;
        while end < entries.len()
            && (entries[end].cmp(&entries[end - 1]) == Ordering::Less) == descending
        {
            end += 1
        }
        let mut run: Vec<_> = (start..end).collect();
        if descending {
            run.reverse();
        }
        while end < entries.len() && run.len() < minimum {
            let at = boundary(&run, |x| entries[end].cmp(&entries[x]) != Ordering::Less);
            run.insert(at, end);
            end += 1;
        }
        runs.push(run);
        start = end;
        while runs.len() >= 2 {
            let n = runs.len() - 2;
            let slot = if n > 0 && runs[n - 1].len() <= runs[n].len() + runs[n + 1].len()
                || n > 1 && runs[n - 2].len() <= runs[n - 1].len() + runs[n].len()
            {
                if runs[n - 1].len() < runs[n + 1].len() {
                    n - 1
                } else {
                    n
                }
            } else if runs[n].len() <= runs[n + 1].len() {
                n
            } else {
                break;
            };
            merge(entries, &mut runs, slot);
        }
    }
    while runs.len() >= 2 {
        let n = runs.len() - 2;
        let slot = if n > 0 && runs[n - 1].len() < runs[n + 1].len() {
            n - 1
        } else {
            n
        };
        merge(entries, &mut runs, slot);
    }
    runs.pop().unwrap_or_default()
}

fn boundary(values: &[usize], mut before: impl FnMut(usize) -> bool) -> usize {
    let (mut low, mut high) = (0, values.len());
    while low < high {
        let mid = (low + high) / 2;
        if before(values[mid]) {
            low = mid + 1
        } else {
            high = mid
        }
    }
    low
}

fn merge(entries: &[impl CatalogueOrder], runs: &mut Vec<Vec<usize>>, slot: usize) {
    let right = runs.remove(slot + 1);
    let left = std::mem::take(&mut runs[slot]);
    let out = &mut runs[slot];
    let first = boundary(&left, |x| {
        entries[right[0]].cmp(&entries[x]) != Ordering::Less
    });
    let end = boundary(&right, |x| {
        entries[left[left.len() - 1]].cmp(&entries[x]) == Ordering::Greater
    });
    out.extend_from_slice(&left[..first]);
    let (a, b) = (&left[first..], &right[..end]);
    if a.len() <= b.len() {
        let (mut i, mut j) = (0, 0);
        while i < a.len() && j < b.len() {
            if entries[b[j]].cmp(&entries[a[i]]) == Ordering::Less {
                out.push(b[j]);
                j += 1
            } else {
                out.push(a[i]);
                i += 1
            }
        }
        out.extend_from_slice(&a[i..]);
        out.extend_from_slice(&b[j..]);
    } else {
        let (mut i, mut j) = (a.len(), b.len());
        let start = out.len();
        while i > 0 && j > 0 {
            if entries[b[j - 1]].cmp(&entries[a[i - 1]]) == Ordering::Less {
                i -= 1;
                out.push(a[i]);
            } else {
                j -= 1;
                out.push(b[j]);
            }
        }
        out.extend(a[..i].iter().rev());
        out.extend(b[..j].iter().rev());
        out[start..].reverse();
    }
    out.extend_from_slice(&right[end..]);
}

pub(super) fn locked_instances(board: &Board) -> Vec<HintStep> {
    let mut entries = Vec::new();
    for (c, &mask) in board
        .masks
        .iter()
        .enumerate()
        .filter(|(_, m)| m.count_ones() == 1)
    {
        entries.push(SortEntry {
            cells: vec![c],
            digits: mask,
            raw: Vec::new(),
            weight: 0,
            locked: None,
        });
    }
    for size in 2..=4 {
        for unit in UNITS[18..].iter().chain(&UNITS[..18]) {
            let cells: Vec<_> = unit
                .iter()
                .copied()
                .filter(|&c| (1..=size).contains(&(board.masks[c].count_ones() as usize)))
                .collect();
            combinations(
                board,
                &cells,
                size,
                &mut Vec::with_capacity(size),
                0,
                &mut entries,
            );
        }
    }
    ordered_runs(&entries)
        .into_iter()
        .filter_map(|i| entries[i].locked.clone())
        .collect()
}
