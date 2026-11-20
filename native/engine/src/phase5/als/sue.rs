// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from MiscellaneousSolver.checkIntersection and checkHouses.
use super::*;

/// Java's stack visits nonempty subsets in depth-first increasing-index order.
fn subsets<T>(
    mut left: u128,
    chosen: u128,
    mask: u16,
    masks: &[u16; 81],
    visit: &mut impl FnMut(u128, u16) -> Option<T>,
) -> Option<T> {
    while left != 0 {
        let i = left.trailing_zeros() as usize;
        left &= left - 1;
        let set = chosen | 1 << i;
        let cand = mask | masks[i];
        if let Some(result) = visit(set, cand) {
            return Some(result);
        }
        if let Some(result) = subsets(left, set, cand, masks, visit) {
            return Some(result);
        }
    }
    None
}
fn contents(masks: &[u16; 81], set: u128, allowed: u16) -> Vec<(u8, u8)> {
    cells(set)
        .flat_map(|i| digits(masks[usize::from(i)] & allowed).map(move |d| (i, d)))
        .collect()
}
fn intersection(
    masks: &[u16; 81],
    line: u128,
    block: u128,
    inter: u128,
    accept: &mut dyn FnMut(Step) -> Option<Step>,
) -> Option<Step> {
    let pool = cells(inter).fold(0, |mask, i| mask | masks[usize::from(i)]);
    let extra = pool.count_ones() as i32 - inter.count_ones() as i32;
    if extra < 2 {
        return None;
    }
    subsets(line & !inter, 0, 0, masks, &mut |a, ca| {
        let count = a.count_ones() as i32 - (ca & !pool).count_ones() as i32;
        if ca & pool == 0 || !(1..extra).contains(&count) {
            return None;
        }
        subsets(block & !inter & !a, 0, 0, masks, &mut |b, cb| {
            if cb & ca & pool != 0
                || cb & pool == 0
                || b.count_ones() as i32 - (cb & !pool).count_ones() as i32 != extra - count
            {
                return None;
            }
            let mut deletes = contents(masks, block & !b & !inter, (pool | cb) & !ca | (cb & ca));
            deletes.extend(contents(
                masks,
                line & !a & !inter,
                (pool | ca) & !cb | (cb & ca),
            ));
            if deletes.is_empty() {
                return None;
            }
            accept(Step {
                kind: "SUE_DE_COQ",
                indices: cells(inter).collect(),
                values: digits(pool).collect(),
                deletes,
                fins: contents(masks, a | inter, ca),
                endo_fins: contents(masks, b | inter, cb),
                alses: [(inter, pool), (b, cb), (a, ca)]
                    .into_iter()
                    .map(|(i, c)| (cells(i).collect(), digits(c).collect()))
                    .collect(),
                ..Step::default()
            })
        })
    })
}
pub(super) fn search(
    masks: &[u16; 81],
    accept: &mut dyn FnMut(Step) -> Option<Step>,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    let unfilled = masks
        .iter()
        .enumerate()
        .filter(|(_, m)| **m != 0)
        .fold(0u128, |set, (i, _)| set | 1 << i);
    for &line in &UNITS[..18] {
        if cancelled() {
            return None;
        }
        for &block in &UNITS[18..] {
            let common = line & block & unfilled;
            if common.count_ones() < 2 {
                continue;
            }
            if let Some(step) = subsets(common, 0, 0, masks, &mut |set, _| {
                if set.count_ones() >= 2 {
                    intersection(masks, line & unfilled, block & unfilled, set, accept)
                } else {
                    None
                }
            }) {
                return Some(step);
            }
        }
    }
    None
}
