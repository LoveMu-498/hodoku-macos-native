// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from HoDoKu FishSolver.searchForKraken and TablingSolver.checkKrakenTypeOne/Two.
use super::graph::{Graph, Reach};
use crate::phase5::advanced::fish::{self, common_peers, houses, Selection, BOXES, COLS, ROWS};
use crate::phase5::advanced::{cells, UNITS};
use crate::phase5::Step;
use std::collections::HashMap;

#[derive(Clone, Copy)]
pub struct Options {
    pub max_kind: u8,
    pub max_size: u8,
    pub max_fins: u8,
    pub max_endo: u8,
    pub siamese: bool,
    pub allow_als: bool,
    pub max_entries: usize,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            max_kind: 1,
            max_size: 4,
            max_fins: 2,
            max_endo: 0,
            siamese: false,
            allow_als: false,
            max_entries: 1000,
        }
    }
}

struct Start {
    reach: Reach,
    off: [u128; 10],
}
fn rank(step: &Step) -> ((usize, u32, bool), usize) {
    (
        fish::rank(step.subtype.unwrap_or(step.kind)),
        super::graph::length(step),
    )
}
#[derive(Default)]
struct Catalogue {
    steps: Vec<Step>,
    best: HashMap<(&'static str, u8, u8), usize>,
}
impl Catalogue {
    fn offer(&mut self, step: Step) -> bool {
        let (cell, digit) = step.deletes[0];
        let target = (step.kind, cell, digit);
        if let Some(&old) = self.best.get(&target) {
            if rank(&self.steps[old]) <= rank(&step) {
                return false;
            }
        }
        // addKrakenStep stores the newly preferred proof as well as the original.
        self.best.insert(target, self.steps.len());
        self.steps.push(step);
        true
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    First,
    Siamese,
    Named,
    Fine,
}
struct Search<'a> {
    mode: Mode,
    baseline_failure: bool,
    matches: Option<&'a dyn Fn(&Step) -> bool>,
    min_size: u8,
    catalogue: Option<Catalogue>,
    options: Options,
    digit: u8,
    positions: [u128; 27],
    graph: &'a Graph,
    ids: &'a [[usize; 10]; 81],
    starts: Vec<Option<Start>>,
    covers: u32,
    cancelled: &'a dyn Fn() -> bool,
}
impl Search<'_> {
    fn bases(&mut self, mut pool: u32, base: Selection) -> Option<Step> {
        while pool != 0 {
            if (self.cancelled)() {
                return None;
            }
            let h = pool.trailing_zeros() as usize;
            pool &= pool - 1;
            let positions = self.positions[h];
            let overlap = base.positions & positions;
            if overlap != 0
                && (self.options.max_kind == 0
                    || overlap.count_ones() + base.repeated.count_ones()
                        > u32::from(self.options.max_endo))
            {
                continue;
            }
            let next = base.add(1 << h, positions);
            let size = next.units.count_ones();
            if size >= u32::from(self.min_size) {
                let mut choices = self.covers & !next.units;
                for u in houses(choices) {
                    if self.positions[usize::from(u)] & next.positions == 0 {
                        choices &= !(1 << u)
                    }
                }
                if let Some(step) = self.cover(next, choices, size, Selection::default()) {
                    // The first accepted proof ends this cover search. In
                    // Siamese mode other bases must still be enumerated.
                    if self.mode != Mode::Siamese || self.baseline_failure {
                        return Some(step);
                    }
                }
            }
            if size < u32::from(self.options.max_size) {
                if let Some(step) = self.bases(pool, next) {
                    return Some(step);
                }
            }
        }
        None
    }
    fn cover(
        &mut self,
        base: Selection,
        mut pool: u32,
        remaining: u32,
        cover: Selection,
    ) -> Option<Step> {
        if (self.cancelled)() {
            return None;
        }
        if remaining == 0 {
            return self.finish(base, cover);
        }
        while pool.count_ones() >= remaining {
            let h = pool.trailing_zeros() as usize;
            pool &= pool - 1;
            if let Some(step) = self.cover(
                base,
                pool,
                remaining - 1,
                cover.add(1 << h, self.positions[h]),
            ) {
                return Some(step);
            }
        }
        None
    }
    fn offer(&mut self, step: Step) -> Option<Step> {
        if self.options.max_kind == 0
            && matches!(self.mode, Mode::First | Mode::Siamese)
            && step.subtype.is_some_and(|name| name.starts_with("FINNED_"))
        {
            self.baseline_failure = true;
            return Some(step);
        }
        let Some(all) = &mut self.catalogue else {
            return Some(step);
        };
        if let Some(accept) = self.matches {
            // createFishStep records a cannibalistic elimination and Type 1
            // appends the target again. The collector sees both, before
            // addKrakenStep normalizes the public recommendation.
            let mut step = step;
            if step.kind == "KRAKEN_FISH_TYPE_1" && !step.cannibalistic.is_empty() {
                step.deletes.extend_from_slice(&step.cannibalistic);
            }
            if accept(&step) {
                all.steps.push(step)
            }
            return None;
        }
        if !all.offer(step) {
            return None;
        }
        if self.mode == Mode::Siamese {
            all.steps.last().cloned()
        } else {
            None
        }
    }
    fn finish(&mut self, base: Selection, cover: Selection) -> Option<Step> {
        let fins = (base.positions & !cover.positions) | base.repeated;
        if fins == 0 || fins.count_ones() > u32::from(self.options.max_fins) {
            return None;
        }
        let potential = (cover.positions & !base.positions) | cover.repeated;
        let viewers = common_peers(fins);
        if viewers == 0 || potential & viewers != 0 {
            return None;
        }

        // Every fin ON implies this potential elimination must be OFF.
        let mut targets = potential;
        for c in cells(fins) {
            targets &= self.starts[c as usize].as_ref()?.off[self.digit as usize]
        }
        for cell in cells(targets) {
            let step = self.step(base, cover, fins, potential, fins, cell, self.digit, true);
            if let Some(out) = self.offer(step) {
                return Some(out);
            }
        }

        // A cover house's body candidates and all fins must share a target;
        // a house entirely contained in the body is a normal forcing chain.
        for unit in houses(cover.units) {
            let unit_cells = self.positions[unit as usize];
            let ordinary = unit_cells & base.positions & !cover.repeated;
            if ordinary == unit_cells {
                continue;
            }
            let starts = ordinary | fins;
            for end_digit in 1..=9 {
                let mut targets = self.graph.candidates[end_digit] & !starts;
                for c in cells(starts) {
                    targets &= self.starts[c as usize].as_ref()?.off[end_digit]
                }
                for cell in cells(targets) {
                    let step = self.step(
                        base,
                        cover,
                        fins,
                        potential,
                        starts,
                        cell,
                        end_digit as u8,
                        false,
                    );
                    if let Some(out) = self.offer(step) {
                        return Some(out);
                    }
                }
            }
        }
        None
    }
    #[allow(clippy::too_many_arguments)]
    fn step(
        &self,
        base: Selection,
        cover: Selection,
        fins: u128,
        potential: u128,
        starts: u128,
        target: u8,
        end_digit: u8,
        first_type: bool,
    ) -> Step {
        let pairs = |cells_set| cells(cells_set).map(|c| (c, self.digit)).collect();
        let end = self.ids[target as usize][end_digit as usize] * 2;
        let chains = cells(starts)
            .filter_map(|c| self.starts[c as usize].as_ref())
            .map(|s| {
                s.reach
                    .path(end)
                    .into_iter()
                    .map(|n| self.graph.code(n))
                    .collect()
            })
            .collect();
        let class = fish::classify(base, cover, fins, &self.positions);
        let cannibalistic = if first_type && cover.repeated & (1 << target) != 0 {
            vec![(target, end_digit)]
        } else {
            vec![]
        };
        let mut step = Step {
            kind: if first_type {
                "KRAKEN_FISH_TYPE_1"
            } else {
                "KRAKEN_FISH_TYPE_2"
            },
            subtype: Some(fish::NAMES[class][base.units.count_ones() as usize - 2]),
            indices: cells(base.positions & !fins).collect(),
            values: vec![self.digit],
            deletes: vec![(target, end_digit)],
            fins: pairs(fins & !base.repeated),
            endo_fins: pairs(base.repeated),
            potential: pairs(potential),
            potential_cannibalistic: cannibalistic.clone(),
            cannibalistic,
            bases: houses(base.units).collect(),
            covers: houses(cover.units).collect(),
            chains,
            ..Step::default()
        };
        self.graph.adjust(&mut step);
        step
    }
}
/// With BASIC-only Kraken search, Java caches a non-Sashimi fish as a different
/// requested subtype and then dereferences the missing step. No Java grade or
/// proof exists in that branch. Report the boundary to the rating caller.
#[derive(Debug, Clone, Copy)]
pub struct BaselineError;
pub fn first(
    masks: &[u16; 81],
    options: &Options,
    cancelled: &dyn Fn() -> bool,
) -> Result<Option<Step>, BaselineError> {
    let result = search(masks, options, 2, 511, None, None, cancelled);
    if options.max_kind == 0
        && result
            .as_ref()
            .and_then(|s| s.subtype)
            .is_some_and(|kind| kind.starts_with("FINNED_"))
    {
        Err(BaselineError)
    } else {
        Ok(result)
    }
}

/// FindAllSteps enumerates each enabled digit separately. Within a digit the
/// array keeps every subsequently improved proof for each elimination.
pub fn catalogue(
    masks: &[u16; 81],
    kind: &str,
    options: &Options,
    min_size: u8,
    digits: u16,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    let mut all = Vec::new();
    search(
        masks,
        options,
        min_size,
        digits,
        Some(&mut all),
        None,
        cancelled,
    );
    if cancelled() {
        return Vec::new();
    }
    all.retain(|s| kind == "KRAKEN_FISH" || s.kind == kind);
    all
}

pub fn fine_proofs(
    masks: &[u16; 81],
    kind: &str,
    options: &Options,
    min_size: u8,
    digits: u16,
    matches: &dyn Fn(&Step) -> bool,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    let mut all = Vec::new();
    let accept = |s: &Step| (kind == "KRAKEN_FISH" || s.kind == kind) && matches(s);
    search(
        masks,
        options,
        min_size,
        digits,
        Some(&mut all),
        Some(&accept),
        cancelled,
    );
    if cancelled() {
        Vec::new()
    } else {
        all
    }
}

fn search(
    masks: &[u16; 81],
    options: &Options,
    min_size: u8,
    digits: u16,
    mut collect: Option<&mut Vec<Step>>,
    matches: Option<&dyn Fn(&Step) -> bool>,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    if cancelled()
        || options.max_fins == 0
        || options.max_entries == 0
        || !(2..=7).contains(&options.max_size)
        || min_size < 2
        || min_size > options.max_size
        || options.max_kind > 2
    {
        return None;
    }
    let mode = if matches.is_some() {
        Mode::Fine
    } else if collect.is_some() {
        Mode::Named
    } else if options.siamese {
        Mode::Siamese
    } else {
        Mode::First
    };
    let mut graph = Graph::new(masks, true);
    if options.allow_als {
        graph.include_als(masks, cancelled)
    }
    let mut ids = [[usize::MAX; 10]; 81];
    for (id, n) in graph.nodes[..graph.ordinary].iter().enumerate() {
        ids[n.cell][n.digit as usize] = id;
    }
    for d in 1..=9 {
        if cancelled() {
            return None;
        }
        let positions = graph.candidates[d];
        if positions == 0 || digits & (1 << (d - 1)) == 0 {
            continue;
        }
        let unit_positions = UNITS.map(|u| u & positions);
        let present =
            unit_positions
                .iter()
                .enumerate()
                .fold(0, |b, (u, v)| if *v != 0 { b | (1 << u) } else { b });
        let mut starts: Vec<_> = (0..81).map(|_| None).collect();
        for c in cells(positions) {
            if cancelled() {
                return None;
            }
            let reach = graph.reachable(2 * ids[c as usize][d] + 1, options.max_entries);
            let mut off = [0; 10];
            for &n in &reach.queue {
                if n & 1 == 0 && n / 2 < graph.ordinary {
                    let node = graph.node(n);
                    off[node.digit as usize] |= node.cells;
                }
            }
            starts[c as usize] = Some(Start { reach, off });
        }
        let mut search = Search {
            min_size,
            catalogue: (mode != Mode::First).then(Catalogue::default),
            mode,
            baseline_failure: false,
            matches,
            options: *options,
            digit: d as u8,
            positions: unit_positions,
            graph: &graph,
            ids: &ids,
            starts,
            covers: 0,
            cancelled,
        };
        for (mut base, mut cover) in [(ROWS, COLS), (COLS, ROWS)] {
            if options.max_kind > 0 {
                base |= BOXES;
                cover |= BOXES;
            }
            if options.max_kind == 2 {
                base = ROWS | COLS | BOXES;
                cover = base;
            }
            search.covers = cover & present;
            if let Some(step) = search.bases(base & present, Selection::default()) {
                return Some(step);
            }
            if options.max_kind == 2 {
                break;
            }
        }
        if let Some(mut batch) = search.catalogue {
            if mode == Mode::Siamese && !batch.steps.is_empty() {
                fish::add_siamese(&mut batch.steps, cancelled);
                return batch
                    .steps
                    .into_iter()
                    .min_by_key(|s| (std::cmp::Reverse(s.deletes.len()), rank(s)));
            }
            if let Some(results) = collect.as_deref_mut() {
                if mode != Mode::Fine {
                    batch.steps.sort_by_key(rank)
                }
                results.extend(batch.steps);
            }
        }
    }
    None
}
