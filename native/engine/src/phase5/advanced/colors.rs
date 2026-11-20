// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from ColoringSolver.java (Bernhard Hobiger).
use super::{candidates, cells, houses, pair, Step, PEERS, UNITS};
use std::ops::ControlFlow;

fn components(positions: u128) -> Vec<[u128; 2]> {
    fn color(
        cell: u8,
        side: usize,
        unseen: &mut u128,
        result: &mut [u128; 2],
        links: &[Option<[u8; 2]>; 27],
    ) {
        let bit = 1u128 << cell;
        if *unseen & bit == 0 {
            return;
        }
        *unseen ^= bit;
        result[side] |= bit;
        for h in houses(cell as usize) {
            if let Some(ends) = links[h] {
                color(
                    if ends[0] == cell { ends[1] } else { ends[0] },
                    1 - side,
                    unseen,
                    result,
                    links,
                );
            }
        }
    }
    let links = UNITS.map(|unit| pair(unit & positions));
    let mut unseen = links
        .iter()
        .flatten()
        .fold(0u128, |v, [a, b]| v | (1u128 << a) | (1u128 << b));
    let mut groups = vec![];
    while unseen != 0 {
        let mut group = [0; 2];
        color(
            unseen.trailing_zeros() as u8,
            0,
            &mut unseen,
            &mut group,
            &links,
        );
        groups.push(group);
    }
    groups
}
fn visible(set: u128) -> u128 {
    cells(set).fold(0, |v, c| v | PEERS[c as usize])
}
fn wrap(group: [u128; 2], digit: u8, valid: impl Fn(u128) -> bool) -> Vec<(u8, u8)> {
    group
        .into_iter()
        .filter(|&part| valid(part))
        .flat_map(|p| candidates(p, digit))
        .collect()
}
fn step(name: &'static str, digit: u8, groups: &[u128], deletes: Vec<(u8, u8)>) -> Step {
    let mut colors = Vec::new();
    for (index, &bits) in groups.iter().enumerate() {
        colors.extend(cells(bits).map(|c| (c, index as i32)));
    }
    colors.sort_by_key(|p| p.0);
    Step {
        kind: name,
        values: vec![digit],
        deletes,
        colors,
        ..Default::default()
    }
}
pub(super) fn search(
    sets: &[u128; 10],
    multi: bool,
    emit: &mut dyn FnMut(Step) -> ControlFlow<Step>,
) -> ControlFlow<Step> {
    for (d, &positions) in sets.iter().enumerate().skip(1) {
        let d = d as u8;
        let groups = components(positions);
        for (i, &a) in groups.iter().enumerate() {
            if !multi {
                let deletes = wrap(a, d, |p| visible(p) & p != 0);
                if !deletes.is_empty() {
                    emit(step("SIMPLE_COLORS_WRAP", d, &a, deletes))?;
                }
                let trapped = visible(a[0]) & visible(a[1]) & positions;
                if trapped != 0 {
                    emit(step("SIMPLE_COLORS_TRAP", d, &a, candidates(trapped, d)))?;
                }
                continue;
            }
            for (j, &b) in groups.iter().enumerate() {
                if i == j {
                    continue;
                }
                let parts = [a[0], a[1], b[0], b[1]];
                let deletes = wrap(a, d, |p| {
                    let peers = visible(p);
                    peers & b[0] != 0 && peers & b[1] != 0
                });
                if !deletes.is_empty() {
                    emit(step("MULTI_COLORS_2", d, &parts, deletes))?;
                }
                let mut deletes = Vec::new();
                for x in 0..2 {
                    for y in 0..2 {
                        if visible(a[x]) & b[y] != 0 {
                            deletes.extend(candidates(
                                positions & visible(a[1 - x]) & visible(b[1 - y]),
                                d,
                            ));
                        }
                    }
                }
                if !deletes.is_empty() {
                    emit(step("MULTI_COLORS_1", d, &parts, deletes))?;
                }
            }
        }
    }
    ControlFlow::Continue(())
}
