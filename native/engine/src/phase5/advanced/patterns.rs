// SPDX-License-Identifier: GPL-3.0-or-later
// Orders follow WingSolver, SingleDigitPatternSolver and UniquenessSolver in the frozen mac-app.
use super::{candidates, cells, digits, houses, pair, sees, Step, PEERS, UNITS};
use std::ops::ControlFlow;

pub(super) fn wing(
    masks: &[u16; 81],
    sets: &[u128; 10],
    xyz: bool,
    emit: &mut dyn FnMut(Step) -> ControlFlow<Step>,
) -> ControlFlow<Step> {
    let with_count = |n| {
        (0..81u8)
            .filter(|&c| masks[c as usize].count_ones() == n)
            .collect::<Vec<_>>()
    };
    let bi = with_count(2);
    let tri = if xyz { with_count(3) } else { Vec::new() };
    let pivots = if xyz { &tri } else { &bi };
    for (i, &a) in pivots.iter().enumerate() {
        for (j, &b) in bi.iter().enumerate().skip(if xyz { 0 } else { i + 1 }) {
            let ma = masks[a as usize];
            let mb = masks[b as usize];
            if (ma | mb).count_ones() != 3 {
                continue;
            }
            for &c in &bi[j + 1..] {
                let mc = masks[c as usize];
                if (ma | mb | mc).count_ones() != 3 || mb == mc || ma == mc {
                    continue;
                }
                for &(p, l, r) in &[(a, b, c), (b, a, c), (c, b, a)][..if xyz { 1 } else { 3 }] {
                    if !sees(p, l) || !sees(p, r) {
                        continue;
                    }
                    let common = masks[l as usize] & masks[r as usize];
                    if common.count_ones() != 1 {
                        continue;
                    }
                    let d = common.trailing_zeros() as u8 + 1;
                    let mut targets = PEERS[l as usize] & PEERS[r as usize] & sets[d as usize];
                    if xyz {
                        targets &= PEERS[p as usize];
                    }
                    if targets == 0 {
                        continue;
                    }
                    let mut values = digits(masks[p as usize]).collect::<Vec<_>>();
                    let mut fins = Vec::new();
                    if xyz {
                        fins.push((p, d));
                    } else {
                        values.push(d);
                    }
                    fins.extend([(l, d), (r, d)]);
                    emit(Step {
                        kind: if xyz { "XYZ_WING" } else { "XY_WING" },
                        values,
                        indices: vec![p, l, r],
                        fins,
                        deletes: candidates(targets, d),
                        ..Default::default()
                    })?;
                }
            }
        }
    }
    ControlFlow::Continue(())
}

pub(super) fn w_wing(
    masks: &[u16; 81],
    sets: &[u128; 10],
    emit: &mut dyn FnMut(Step) -> ControlFlow<Step>,
) -> ControlFlow<Step> {
    for (a, &ma) in masks
        .iter()
        .enumerate()
        .filter(|(_, m)| m.count_ones() == 2)
    {
        for (b, &_) in masks
            .iter()
            .enumerate()
            .skip(a + 1)
            .filter(|(_, m)| **m == ma)
        {
            for d in digits(ma) {
                let link = (ma ^ (1 << (d - 1))).trailing_zeros() as u8 + 1;
                let targets = PEERS[a] & PEERS[b] & sets[d as usize];
                if targets == 0 {
                    continue;
                }
                for unit in UNITS {
                    if let Some(ends) = pair(unit & sets[link as usize]) {
                        let a = a as u8;
                        let b = b as u8;
                        let mut l = None;
                        let mut r = None;
                        for e in ends {
                            if e == a || e == b {
                                continue;
                            }
                            if sees(e, a) {
                                l = Some(e);
                            } else if sees(e, b) {
                                r = Some(e);
                            }
                        }
                        if let (Some(left), Some(right)) = (l, r) {
                            emit(Step {
                                kind: "W_WING",
                                indices: vec![a, b],
                                values: vec![d, link],
                                fins: vec![(a, link), (b, link), (left, link), (right, link)],
                                deletes: candidates(targets, d),
                                ..Default::default()
                            })?;
                        }
                    }
                }
            }
        }
    }
    ControlFlow::Continue(())
}

pub(super) fn skyscraper(
    sets: &[u128; 10],
    emit: &mut dyn FnMut(Step) -> ControlFlow<Step>,
) -> ControlFlow<Step> {
    for start in [0, 9] {
        let cross = |c: u8| if start == 0 { c % 9 } else { c / 9 };
        for (d, &positions) in sets.iter().enumerate().skip(1) {
            let links = UNITS[start..start + 9]
                .iter()
                .filter_map(|u| pair(u & positions))
                .collect::<Vec<_>>();
            for (i, a) in links.iter().enumerate() {
                for b in &links[i + 1..] {
                    let end = if cross(a[0]) == cross(b[0]) {
                        1
                    } else if cross(a[1]) == cross(b[1]) {
                        0
                    } else {
                        continue;
                    };
                    if cross(a[end]) == cross(b[end]) {
                        continue;
                    }
                    let targets = PEERS[a[end] as usize] & PEERS[b[end] as usize] & positions;
                    if targets != 0 {
                        emit(Step {
                            kind: "SKYSCRAPER",
                            values: vec![d as u8],
                            indices: vec![a[end], b[end], a[1 - end], b[1 - end]],
                            deletes: candidates(targets, d as u8),
                            ..Default::default()
                        })?;
                    }
                }
            }
        }
    }
    ControlFlow::Continue(())
}

pub(super) fn kite(
    sets: &[u128; 10],
    emit: &mut dyn FnMut(Step) -> ControlFlow<Step>,
) -> ControlFlow<Step> {
    for (d, &positions) in sets.iter().enumerate().skip(1) {
        let links = |units: &[u128]| {
            units
                .iter()
                .filter_map(|u| pair(u & positions))
                .collect::<Vec<_>>()
        };
        let mut cols = links(&UNITS[9..18]);
        for mut row in links(&UNITS[..9]) {
            for col in &mut cols {
                let Some((i, j)) = [(0, 0), (0, 1), (1, 0), (1, 1)]
                    .into_iter()
                    .find(|&(i, j)| houses(row[i] as usize)[2] == houses(col[j] as usize)[2])
                else {
                    continue;
                };
                // Java keeps these swaps for the next pair even if this pair has no elimination.
                row.swap(0, i);
                col.swap(0, j);
                if row.iter().any(|x| col.contains(x)) {
                    continue;
                }
                let target = col[1] / 9 * 9 + row[1] % 9;
                if positions & (1u128 << target) != 0 {
                    let d = d as u8;
                    emit(Step {
                        kind: "TWO_STRING_KITE",
                        values: vec![d],
                        indices: vec![row[1], col[1], row[0], col[0]],
                        fins: vec![(row[0], d), (col[0], d)],
                        deletes: vec![(target, d)],
                        ..Default::default()
                    })?;
                }
            }
        }
    }
    ControlFlow::Continue(())
}

pub(super) fn rectangle(
    sets: &[u128; 10],
    two_candidates: bool,
    emit: &mut dyn FnMut(Step) -> ControlFlow<Step>,
) -> ControlFlow<Step> {
    for (d, &positions) in sets.iter().enumerate().skip(1) {
        for block in 0..9 {
            let block_cells = UNITS[block + 18] & positions;
            if !((if two_candidates { 2 } else { 3 })..=5).contains(&block_cells.count_ones()) {
                continue;
            }
            for dy in (0..3).rev() {
                for dx in (0..3).rev() {
                    let row = block / 3 * 3 + dy;
                    let col = block % 3 * 3 + dx;
                    let h = UNITS[row];
                    let v = UNITS[9 + col];
                    if block_cells & !(h | v) != 0
                        || block_cells & h & !v == 0
                        || block_cells & v & !h == 0
                    {
                        continue;
                    }
                    for (line, reverse) in [(h, false), (v, true)] {
                        for a in cells(positions & line & !block_cells) {
                            let links = if reverse {
                                UNITS[a as usize / 9]
                            } else {
                                UNITS[9 + a as usize % 9]
                            };
                            if let Some(ends) = pair(positions & links) {
                                let b = if ends[0] == a { ends[1] } else { ends[0] };
                                let target = if reverse {
                                    row * 9 + b as usize % 9
                                } else {
                                    b as usize / 9 * 9 + col
                                };
                                if houses(target)[2] != block + 18
                                    && positions & (1u128 << target) != 0
                                {
                                    let d = d as u8;
                                    emit(Step {
                                        kind: "EMPTY_RECTANGLE",
                                        house: Some((block + 18) as u8),
                                        values: vec![d],
                                        indices: vec![a, b],
                                        fins: candidates(block_cells, d),
                                        deletes: vec![(target as u8, d)],
                                        ..Default::default()
                                    })?;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    ControlFlow::Continue(())
}

pub(super) fn bug(masks: &[u16; 81], sets: &[u128; 10]) -> Option<Step> {
    let mut tri = None;
    for (c, &m) in masks.iter().enumerate() {
        if m.count_ones() > 3 || (m.count_ones() == 3 && tri.replace(c).is_some()) {
            return None;
        }
    }
    let c = tri?;
    let mut digit = None;
    let mut constraints = [usize::MAX; 3];
    for (i, &unit) in UNITS.iter().enumerate() {
        for (d, &positions) in sets.iter().enumerate().skip(1) {
            match (unit & positions).count_ones() {
                4.. => return None,
                3 if constraints[i / 9] != usize::MAX || digit.is_some_and(|old| old != d) => {
                    return None
                }
                3 => {
                    constraints[i / 9] = i;
                    digit = Some(d);
                }
                _ => {}
            }
        }
    }
    let d = digit?;
    if constraints != houses(c) || masks[c] & (1 << (d - 1)) == 0 {
        return None;
    }
    Some(Step {
        kind: "BUG_PLUS_1",
        deletes: digits(masks[c])
            .filter(|x| *x as usize != d)
            .map(|v| (c as u8, v))
            .collect(),
        ..Default::default()
    })
}
