// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from AlsSolver.java and SudokuStepFinder.java, Bernhard Hobiger.
use super::advanced::{cells, digit_sets, PEERS, UNITS};
use super::Step;
use crate::board::digits;
use std::cmp::Ordering;
use std::collections::HashSet;
mod chain;
mod sue;

pub fn supports(kind: &str) -> bool {
    matches!(
        kind,
        "ALS_XZ" | "ALS_XY_WING" | "ALS_XY_CHAIN" | "DEATH_BLOSSOM" | "SUE_DE_COQ"
    )
}

#[derive(Clone)]
pub(super) struct Als {
    pub(super) cells: u128,
    pub(super) mask: u16,
    pub(super) inside: [u128; 10],
    pub(super) outside: [u128; 10],
}
impl Als {
    fn new(cells: u128, mask: u16, positions: &[u128; 10]) -> Self {
        let inside = std::array::from_fn(|d| cells & positions[d]);
        let outside = std::array::from_fn(|d| {
            if inside[d] == 0 {
                0
            } else {
                buddies(inside[d]) & !cells & positions[d]
            }
        });
        Self {
            cells,
            mask,
            inside,
            outside,
        }
    }
    fn record(&self, step: &mut Step) {
        step.alses
            .push((cells(self.cells).collect(), digits(self.mask).collect()));
    }
}
fn buddies(members: u128) -> u128 {
    cells(members).fold((1 << 81) - 1, |peers, index| {
        peers & PEERS[usize::from(index)]
    })
}
pub(super) fn all(
    masks: &[u16; 81],
    positions: &[u128; 10],
    cancelled: &dyn Fn() -> bool,
) -> Vec<Als> {
    fn visit(
        masks: &[u16; 81],
        left: u128,
        members: u128,
        mask: u16,
        seen: &mut HashSet<u128>,
        groups: &mut Vec<(u128, u16)>,
    ) {
        let mut left = left;
        while left != 0 {
            let cell = left.trailing_zeros() as usize;
            left &= left - 1;
            let next = members | (1u128 << cell);
            let mask = mask | masks[cell];
            if mask.count_ones() == next.count_ones() + 1 && seen.insert(next) {
                groups.push((next, mask));
            }
            if next.count_ones() < 8 {
                visit(masks, left, next, mask, seen, groups);
            }
        }
    }
    let unfilled = positions.iter().fold(0, |a, b| a | b);
    let mut groups = Vec::new();
    let mut seen = HashSet::new();
    for unit in UNITS {
        if cancelled() {
            return Vec::new();
        }
        visit(masks, unit & unfilled, 0, 0, &mut seen, &mut groups);
    }
    groups
        .into_iter()
        .map(|(indices, mask)| Als::new(indices, mask, positions))
        .collect()
}
#[derive(Clone, Copy)]
struct Link {
    a: usize,
    b: usize,
    first: u8,
    second: u8,
}
fn links(groups: &[Als], overlap: bool, cancelled: &dyn Fn() -> bool) -> Vec<Link> {
    let mut result = Vec::new();
    for (i, a) in groups.iter().enumerate() {
        if cancelled() {
            return Vec::new();
        }
        for (j, b) in groups.iter().enumerate().skip(i + 1) {
            let shared = a.cells & b.cells;
            if !overlap && shared != 0 {
                continue;
            }
            let mut rc = Link {
                a: i,
                b: j,
                first: 0,
                second: 0,
            };
            for digit in digits(a.mask & b.mask) {
                let d = usize::from(digit);
                let locations = a.inside[d] | b.inside[d];
                if locations & shared == 0
                    && b.inside[d] & !a.outside[d] == 0
                    && a.inside[d] & !b.outside[d] == 0
                {
                    if rc.first == 0 {
                        rc.first = digit;
                    } else {
                        rc.second = digit;
                    }
                }
            }
            if rc.first != 0 {
                result.push(rc);
            }
        }
    }
    result
}
fn pairs(set: u128, d: u8) -> impl Iterator<Item = (u8, u8)> {
    cells(set).map(move |c| (c, d))
}
fn eliminations(a: &Als, b: &Als, excluded: &[u8], step: &mut Step) {
    for d in digits(a.mask & b.mask).filter(|d| !excluded.contains(d)) {
        let i = usize::from(d);
        let targets = a.outside[i] & b.outside[i];
        if targets != 0 {
            step.deletes.extend(pairs(targets, d));
            step.fins.extend(pairs(a.inside[i] | b.inside[i], d));
        }
    }
}
fn draw_link(a: &Als, b: &Als, digit: u8, as_chain: bool, step: &mut Step) {
    if digit == 0 {
        return;
    }
    let i = usize::from(digit);
    step.endo_fins
        .extend(pairs(a.inside[i] | b.inside[i], digit));
    if as_chain {
        let distance = |a: u8, b: u8| {
            let dr = i32::from(a / 9) - i32::from(b / 9);
            let dc = i32::from(a % 9) - i32::from(b % 9);
            dr * dr + dc * dc
        };
        let best = cells(a.inside[i])
            .flat_map(|a| cells(b.inside[i]).map(move |b| (a, b)))
            .min_by_key(|&(a, b)| distance(a, b));
        if let Some((a, b)) = best {
            step.chains.push(vec![
                (i32::from(a) << 5) | i32::from(digit),
                (i32::from(b) << 5) | i32::from(digit),
            ]);
        }
    }
}
fn xz(groups: &[Als], links: &[Link], visit: &mut dyn FnMut(Step) -> Option<Step>) -> Option<Step> {
    for rc in links {
        if rc.a > rc.b {
            continue;
        }
        let (a, b) = (&groups[rc.a], &groups[rc.b]);
        let mut step = Step {
            kind: "ALS_XZ",
            ..Step::default()
        };
        eliminations(a, b, &[rc.first], &mut step);
        if rc.second != 0 {
            eliminations(a, b, &[rc.second], &mut step);
            let count = step.deletes.len();
            for (x, y) in [(a, b), (b, a)] {
                for d in digits(x.mask).filter(|&d| d != rc.first && d != rc.second) {
                    step.deletes
                        .extend(pairs(x.outside[usize::from(d)] & !y.cells, d));
                }
            }
            if step.deletes.len() > count {
                step.fins.clear();
            }
        }
        if !step.deletes.is_empty() {
            a.record(&mut step);
            b.record(&mut step);
            draw_link(a, b, rc.first, false, &mut step);
            draw_link(a, b, rc.second, false, &mut step);
            if let Some(result) = visit(step) {
                return Some(result);
            }
        }
    }
    None
}
fn xy_wing(
    groups: &[Als],
    links: &[Link],
    overlap: bool,
    visit: &mut dyn FnMut(Step) -> Option<Step>,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    // Retain global Java link order while visiting only incident pairs.
    let mut incident = vec![Vec::new(); groups.len()];
    for (i, rc) in links.iter().enumerate() {
        incident[rc.a].push(i);
        incident[rc.b].push(i);
    }
    for (i, p) in links.iter().enumerate() {
        if cancelled() {
            return None;
        }
        let mut neighbors = Vec::new();
        neighbors.extend(
            incident[p.a]
                .iter()
                .chain(&incident[p.b])
                .copied()
                .filter(|&j| j > i),
        );
        neighbors.sort_unstable();
        neighbors.dedup();
        for j in neighbors {
            let q = links[j];
            if p.a == q.b && p.b == q.a {
                continue;
            }
            if p.second == 0 && q.second == 0 && p.first == q.first {
                continue;
            }
            let (tail, other, hinge) = if p.a == q.a {
                (p.b, q.b, p.a)
            } else if p.a == q.b {
                (p.b, q.a, p.a)
            } else if p.b == q.a {
                (p.a, q.b, p.b)
            } else {
                (p.a, q.a, p.b)
            };
            let (a, b, c) = (&groups[tail], &groups[other], &groups[hinge]);
            if (!overlap && a.cells & b.cells != 0)
                || (a.cells | b.cells) == a.cells
                || (a.cells | b.cells) == b.cells
            {
                continue;
            }
            let mut step = Step {
                kind: "ALS_XY_WING",
                ..Step::default()
            };
            eliminations(a, b, &[p.first, p.second, q.first, q.second], &mut step);
            if !step.deletes.is_empty() {
                a.record(&mut step);
                b.record(&mut step);
                c.record(&mut step);
                for (end, link) in [(a, p), (b, &q)] {
                    draw_link(end, c, link.first, false, &mut step);
                    draw_link(end, c, link.second, false, &mut step);
                }
                if let Some(result) = visit(step) {
                    return Some(result);
                }
            }
        }
    }
    None
}
pub fn first(
    masks: &[u16; 81],
    kind: &str,
    allow_overlap: bool,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    first_with_options(masks, kind, allow_overlap, true, cancelled)
}
pub fn first_with_options(
    masks: &[u16; 81],
    kind: &str,
    allow_overlap: bool,
    only_one_per_step: bool,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    if kind == "SUE_DE_COQ" {
        return sue::search(masks, &mut Some, cancelled);
    }
    let positions = digit_sets(masks);
    let groups = all(masks, &positions, cancelled);
    if kind == "DEATH_BLOSSOM" {
        return chain::blossom(masks, &groups, allow_overlap, &mut Some, cancelled);
    }
    let links = links(&groups, allow_overlap, cancelled);
    match kind {
        "ALS_XZ" => xz(&groups, &links, &mut Some),
        "ALS_XY_WING" => xy_wing(&groups, &links, allow_overlap, &mut Some, cancelled),
        "ALS_XY_CHAIN" => chain::search(
            &groups,
            &links,
            only_one_per_step,
            false,
            50,
            None,
            cancelled,
        )
        .into_iter()
        .next(),
        _ => None,
    }
}

fn cell_count(step: &Step) -> usize {
    step.alses.iter().map(|(set, _)| set.len()).sum()
}
fn compare(a: &Step, b: &Step) -> Ordering {
    let count = b.deletes.len().cmp(&a.deletes.len());
    if count != Ordering::Equal {
        return count;
    }
    // AlsComparator compares different elimination sets by weighted cell order.
    if !a.deletes.iter().all(|c| b.deletes.contains(c)) {
        let weight = |s: &Step| {
            s.deletes
                .iter()
                .enumerate()
                .map(|(i, &(c, d))| (1 + 80 * i) * usize::from(c) + usize::from(d))
                .sum::<usize>()
        };
        return weight(a).cmp(&weight(b));
    }
    a.alses
        .len()
        .cmp(&b.alses.len())
        .then_with(|| cell_count(a).cmp(&cell_count(b)))
}

pub fn catalogue(
    masks: &[u16; 81],
    kind: &str,
    overlap: bool,
    only_one_per_step: bool,
    forward_only: bool,
    max_links: usize,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    enumerate(
        masks,
        kind,
        overlap,
        only_one_per_step,
        forward_only,
        max_links,
        None,
        cancelled,
    )
}

// Keep the named and filtered entry points on the same Java search parameters.
#[allow(clippy::too_many_arguments)]
pub fn fine_proofs(
    masks: &[u16; 81],
    kind: &str,
    overlap: bool,
    only_one_per_step: bool,
    forward_only: bool,
    max_links: usize,
    matches: &dyn Fn(&Step) -> bool,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    enumerate(
        masks,
        kind,
        overlap,
        only_one_per_step,
        forward_only,
        max_links,
        Some(matches),
        cancelled,
    )
}

// In addition to those search settings this accepts the optional pre-deduplication observer.
#[allow(clippy::too_many_arguments)]
fn enumerate(
    masks: &[u16; 81],
    kind: &str,
    overlap: bool,
    only_one_per_step: bool,
    forward_only: bool,
    max_links: usize,
    matches: Option<&dyn Fn(&Step) -> bool>,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    // These two solvers emit NativeProofCollector events before coalescing
    // equivalent deletions. Other ALS families are found in the final ordinary list.
    let raw = matches.filter(|_| matches!(kind, "ALS_XY_CHAIN" | "DEATH_BLOSSOM"));
    let mut steps = Vec::new();
    let mut collect = |step| {
        steps.push(step);
        None
    };
    if kind == "SUE_DE_COQ" {
        sue::search(masks, &mut collect, cancelled);
    } else {
        let positions = digit_sets(masks);
        let groups = all(masks, &positions, cancelled);
        if kind == "DEATH_BLOSSOM" {
            let mut seen = std::collections::HashMap::<Vec<(u8, u8)>, usize>::new();
            let mut save = |step: Step| {
                if raw.is_some_and(|accept| !accept(&step)) {
                    return None;
                }
                if only_one_per_step && raw.is_none() {
                    if let Some(index) = seen.get(&step.deletes).copied() {
                        if cell_count(&step) < cell_count(&steps[index]) {
                            steps[index] = step
                        }
                        return None;
                    }
                    seen.insert(step.deletes.clone(), steps.len());
                }
                steps.push(step);
                None
            };
            chain::blossom(masks, &groups, overlap, &mut save, cancelled);
        } else {
            let mut edges = links(&groups, overlap, cancelled);
            if !forward_only {
                edges.extend_from_within(..);
                let half = edges.len() / 2;
                for rc in &mut edges[half..] {
                    std::mem::swap(&mut rc.a, &mut rc.b);
                }
                edges.sort_by_key(|rc| (rc.a, rc.b));
            }
            match kind {
                "ALS_XZ" => {
                    xz(&groups, &edges, &mut collect);
                }
                "ALS_XY_WING" => {
                    xy_wing(&groups, &edges, overlap, &mut collect, cancelled);
                }
                "ALS_XY_CHAIN" => {
                    steps = chain::search(
                        &groups,
                        &edges,
                        only_one_per_step && raw.is_none(),
                        true,
                        max_links,
                        raw,
                        cancelled,
                    )
                }
                _ => {}
            }
        }
        if raw.is_some() {
            return if cancelled() { vec![] } else { steps };
        }
        // AlsComparator can tie different deletion sets with equal index sums.
        // HoDoKu's stable Java run and merge ordering is observable in named hints.
        use crate::hints::catalogue_order::{ordered_runs, CatalogueOrder};
        struct AlsRank<'a>(&'a Step);
        impl CatalogueOrder for AlsRank<'_> {
            fn cmp(&self, other: &Self) -> Ordering {
                compare(self.0, other.0)
            }
        }
        let order = ordered_runs(&steps.iter().map(AlsRank).collect::<Vec<_>>());
        steps = order
            .into_iter()
            .map(|i| std::mem::take(&mut steps[i]))
            .collect();
    }
    if cancelled() {
        steps.clear()
    } else if let Some(accept) = matches {
        steps.retain(accept)
    }
    steps
}
