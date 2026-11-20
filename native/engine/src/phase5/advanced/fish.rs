// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from HoDoKu FishSolver.getFishes/searchCoverUnits/createFishStep.
use super::{candidates, cells, Options, Step, ALL, PEERS, UNITS};
use crate::phase5::last_resort::templates;

pub(crate) const NAMES: [[&str; 6]; 7] = [
    [
        "X_WING",
        "SWORDFISH",
        "JELLYFISH",
        "SQUIRMBAG",
        "WHALE",
        "LEVIATHAN",
    ],
    [
        "FINNED_X_WING",
        "FINNED_SWORDFISH",
        "FINNED_JELLYFISH",
        "FINNED_SQUIRMBAG",
        "FINNED_WHALE",
        "FINNED_LEVIATHAN",
    ],
    [
        "SASHIMI_X_WING",
        "SASHIMI_SWORDFISH",
        "SASHIMI_JELLYFISH",
        "SASHIMI_SQUIRMBAG",
        "SASHIMI_WHALE",
        "SASHIMI_LEVIATHAN",
    ],
    [
        "FRANKEN_X_WING",
        "FRANKEN_SWORDFISH",
        "FRANKEN_JELLYFISH",
        "FRANKEN_SQUIRMBAG",
        "FRANKEN_WHALE",
        "FRANKEN_LEVIATHAN",
    ],
    [
        "FINNED_FRANKEN_X_WING",
        "FINNED_FRANKEN_SWORDFISH",
        "FINNED_FRANKEN_JELLYFISH",
        "FINNED_FRANKEN_SQUIRMBAG",
        "FINNED_FRANKEN_WHALE",
        "FINNED_FRANKEN_LEVIATHAN",
    ],
    [
        "MUTANT_X_WING",
        "MUTANT_SWORDFISH",
        "MUTANT_JELLYFISH",
        "MUTANT_SQUIRMBAG",
        "MUTANT_WHALE",
        "MUTANT_LEVIATHAN",
    ],
    [
        "FINNED_MUTANT_X_WING",
        "FINNED_MUTANT_SWORDFISH",
        "FINNED_MUTANT_JELLYFISH",
        "FINNED_MUTANT_SQUIRMBAG",
        "FINNED_MUTANT_WHALE",
        "FINNED_MUTANT_LEVIATHAN",
    ],
];

#[derive(Clone, Copy)]
pub(super) struct Spec {
    size: u32,
    class: usize,
}
impl Spec {
    fn finned(self) -> bool {
        matches!(self.class, 1 | 2 | 4 | 6)
    }
    fn mutant(self) -> bool {
        self.class >= 5
    }
    fn mixed(self) -> bool {
        self.class >= 3
    }
    fn screens_templates(self) -> bool {
        self.size
            > if self.mutant() {
                3
            } else if self.mixed() {
                4
            } else {
                5
            }
    }
}
pub(super) fn spec(name: &str) -> Option<Spec> {
    NAMES.iter().enumerate().find_map(|(class, names)| {
        names.iter().position(|n| *n == name).map(|i| Spec {
            size: i as u32 + 2,
            class,
        })
    })
}

pub(crate) const ROWS: u32 = 511;
pub(crate) const COLS: u32 = ROWS << 9;
pub(crate) const BOXES: u32 = ROWS << 18;
pub(crate) fn houses(mask: u32) -> impl Iterator<Item = u8> {
    cells(u128::from(mask))
}
pub(crate) fn common_peers(bits: u128) -> u128 {
    cells(bits).fold(ALL, |seen, c| seen & PEERS[c as usize])
}

#[derive(Clone, Copy, Default)]
pub(crate) struct Selection {
    pub(crate) units: u32,
    pub(crate) positions: u128,
    pub(crate) repeated: u128,
}
impl Selection {
    pub(crate) fn add(self, unit: u32, positions: u128) -> Self {
        Self {
            units: self.units | unit,
            positions: self.positions | positions,
            repeated: self.repeated | (self.positions & positions),
        }
    }
}
pub(crate) fn classify(
    base: Selection,
    cover: Selection,
    fins: u128,
    unit_positions: &[u128; 27],
) -> usize {
    let line_col = |b, c| b & !ROWS == 0 && c & !COLS == 0;
    let line_box_col_box = |b, c| b & COLS == 0 && b & ROWS != 0 && c & ROWS == 0 && c & COLS != 0;
    let (b, c) = (base.units, cover.units);
    if line_col(b, c) || line_col(c, b) {
        let sashimi = houses(b).any(|h| (unit_positions[h as usize] & !fins).count_ones() <= 1);
        if sashimi {
            2
        } else {
            usize::from(fins != 0)
        }
    } else if line_box_col_box(b, c) || line_box_col_box(c, b) {
        3 + usize::from(fins != 0)
    } else {
        5 + usize::from(fins != 0)
    }
}
#[derive(Default)]
struct Catalogue {
    proofs: Vec<Step>,
    steps: Vec<Step>,
    by_eliminations: std::collections::HashMap<Vec<(u8, u8)>, usize>,
}
pub(crate) fn rank(kind: &str) -> (usize, u32, bool) {
    let spec = spec(kind).expect("classified fish");
    let category = if spec.class >= 2 {
        spec.class - 1
    } else {
        spec.class
    };
    (category, spec.size, spec.class == 2)
}
impl Catalogue {
    fn offer(&mut self, mut step: Step, only_one: bool) {
        if !only_one {
            self.steps.push(step);
            return;
        }
        // addFishStep.getCandidateString normalizes eliminations before indexing or copying.
        step.deletes.sort_by_key(|&(cell, digit)| (digit, cell));
        step.deletes.dedup();
        if let Some(&index) = self.by_eliminations.get(&step.deletes) {
            if rank(step.kind) < rank(self.steps[index].kind) {
                self.steps[index] = step;
            }
        } else {
            self.by_eliminations
                .insert(step.deletes.clone(), self.steps.len());
            self.steps.push(step);
        }
    }
}
pub(crate) fn add_siamese(steps: &mut Vec<Step>, cancelled: &dyn Fn() -> bool) {
    let n = steps.len();
    for i in 0..n {
        if cancelled() {
            return;
        }
        for j in i + 1..n {
            if j % 256 == 0 && cancelled() {
                return;
            }
            let (a, b) = (&steps[i], &steps[j]);
            if a.values != b.values
                || a.bases != b.bases
                || !(a.kind.starts_with("KRAKEN_FISH") && b.kind.starts_with("KRAKEN_FISH"))
                    && rank(a.kind).0 != rank(b.kind).0
                || a.deletes[0] == b.deletes[0]
            {
                continue;
            }
            let mut pair = a.clone();
            pair.siamese = true;
            pair.covers.extend(&b.covers);
            pair.fins.extend(&b.fins);
            pair.deletes.extend(&b.deletes);
            for (into, from) in [
                (&mut pair.potential, &b.potential),
                (
                    &mut pair.potential_cannibalistic,
                    &b.potential_cannibalistic,
                ),
            ] {
                into.extend(from);
                into.sort();
                into.dedup();
            }
            steps.push(pair);
        }
    }
}
fn order(
    s: &Step,
) -> (
    std::cmp::Reverse<usize>,
    (usize, u32, bool),
    usize,
    usize,
    usize,
    u8,
) {
    (
        std::cmp::Reverse(s.deletes.len()),
        rank(s.kind),
        s.cannibalistic.len(),
        s.endo_fins.len(),
        s.fins.len(),
        s.values[0],
    )
}
struct Search<'a> {
    fine: Option<(&'a super::FineScope, &'a str)>,
    named: bool,
    min: u32,
    max_fins: u32,
    max_endo: u32,
    one_fish: bool,
    catalogue: Option<&'a mut Catalogue>,
    spec: Spec,
    d: u8,
    positions: u128,
    houses: [u128; 27],
    covers: u32,
    template_del: Option<u128>,
    poll: super::super::NodePoll<'a>,
}
impl Search<'_> {
    fn bases(&mut self, mut pool: u32, need: u32, chosen: Selection) -> Option<Step> {
        if self.poll.cancelled() {
            return None;
        }
        let size = chosen.units.count_ones();
        if need == 0 || self.named && size >= self.min {
            if chosen.repeated != 0
                && self
                    .template_del
                    .is_some_and(|del| common_peers(chosen.repeated) & !self.positions & del == 0)
            {
                return None;
            }
            let mut eligible = self.covers & !chosen.units;
            for h in houses(eligible) {
                if self.houses[h as usize] & chosen.positions == 0 {
                    eligible &= !(1 << h);
                }
            }
            // In a basic fish a base cell belongs to exactly one possible cover.
            if !self.spec.mixed() && !self.spec.finned() && eligible.count_ones() != self.spec.size
            {
                return None;
            }
            if let Some(step) = self.cover(chosen, eligible, size, Selection::default()) {
                return Some(step);
            }
            if need == 0 {
                return None;
            }
        }
        let min_remaining = if self.named { 1 } else { need };
        while pool.count_ones() >= min_remaining {
            let h = pool.trailing_zeros();
            let bit = 1 << h;
            pool ^= bit;
            let positions = self.houses[h as usize];
            let overlap = chosen.positions & positions;
            if overlap != 0
                && (!self.spec.finned()
                    || chosen.repeated.count_ones() + overlap.count_ones() > self.max_endo)
            {
                continue;
            }
            if let Some(s) = self.bases(pool, need - 1, chosen.add(bit, positions)) {
                return Some(s);
            }
        }
        None
    }
    fn cover(
        &mut self,
        base: Selection,
        mut pool: u32,
        need: u32,
        chosen: Selection,
    ) -> Option<Step> {
        if self.poll.cancelled() {
            return None;
        }
        if need == 0 {
            let step = self.finish(base, chosen)?;
            if let Some(all) = &mut self.catalogue {
                if let Some((scope, kind)) = self.fine {
                    if kind == step.kind && scope.might_match(&step) && !all.proofs.contains(&step)
                    {
                        all.proofs.push(step.clone());
                    }
                }
                all.offer(step, self.one_fish);
                return None;
            }
            return Some(step);
        }
        while pool.count_ones() >= need {
            let h = pool.trailing_zeros();
            let bit = 1 << h;
            pool ^= bit;
            if let Some(s) = self.cover(
                base,
                pool,
                need - 1,
                chosen.add(bit, self.houses[h as usize]),
            ) {
                return Some(s);
            }
        }
        None
    }
    fn finish(&self, base: Selection, cover: Selection) -> Option<Step> {
        let fins = (base.positions & !cover.positions) | base.repeated;
        if !self.named && self.spec.finned() != (fins != 0) || fins.count_ones() > self.max_fins {
            return None;
        }
        let potential = cover.positions & !base.positions;
        if potential | cover.repeated == 0 {
            return None;
        }
        let viewers = common_peers(fins);
        let ordinary = potential & viewers;
        let cannibal = cover.repeated & viewers;
        if ordinary | cannibal == 0 {
            return None;
        }

        let class = classify(base, cover, fins, &self.houses);
        if !self.named
            && !self.spec.mixed()
            && self.spec.finned()
            && (self.spec.class == 2) != (class == 2)
        {
            return None;
        }
        if !self.named && self.catalogue.is_some() && (class >= 3) != (self.spec.mixed()) {
            return None;
        }
        if !self.named && self.catalogue.is_some() && (class >= 5) != self.spec.mutant() {
            return None;
        }
        let mut deletes = candidates(ordinary, self.d);
        deletes.extend(candidates(cannibal, self.d));
        Some(Step {
            kind: NAMES[class][base.units.count_ones() as usize - 2],
            values: vec![self.d],
            indices: cells(base.positions & !fins).collect(),
            deletes,
            fins: candidates(fins & !base.repeated, self.d),
            endo_fins: candidates(base.repeated, self.d),
            potential: candidates(potential, self.d),
            cannibalistic: candidates(cannibal, self.d),
            potential_cannibalistic: candidates(cannibal, self.d),
            bases: houses(base.units).collect(),
            covers: houses(cover.units).collect(),
            ..Default::default()
        })
    }
}

// FishSolver uses the single-digit template union (initLists=false), before cross-digit refinement.
fn template_eliminations(placed: u128, positions: u128, cancelled: &dyn Fn() -> bool) -> u128 {
    let allowed = placed | positions;
    let mut union = 0;
    for group in templates().chunks(256) {
        if cancelled() {
            return 0;
        }
        for &t in group {
            if t & placed == placed && t & !allowed == 0 {
                union |= t;
            }
        }
        if positions & !union == 0 {
            return 0;
        }
    }
    ALL & !union
}

fn digit_search(
    values: &[u8; 81],
    sets: &[u128; 10],
    spec: Spec,
    options: &Options,
    mode: Option<&str>,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    let named = mode.is_some();
    let mut result = Vec::new();
    let (min, max_fins, max_endo, check_templates) = if named {
        (
            options.all_min_size,
            options.all_fins,
            options.all_endo,
            options.all_templates,
        )
    } else {
        (
            spec.size,
            options.max_fins,
            options.max_endo,
            options.templates,
        )
    };
    for (d, &positions) in sets.iter().enumerate().skip(1) {
        if cancelled() {
            return vec![];
        }
        if positions == 0 || positions == ALL || named && (options.all_digits & (1 << (d - 1))) == 0
        {
            continue;
        }
        let template_del = (check_templates && spec.screens_templates()).then(|| {
            let placed = values
                .iter()
                .enumerate()
                .filter(|(_, v)| **v == d as u8)
                .fold(0, |s, (i, _)| s | (1 << i));
            template_eliminations(placed, positions, cancelled)
        });
        if template_del.is_some_and(|del| positions & del == 0) {
            continue;
        }
        let houses = UNITS.map(|h| h & positions);
        let eligible = houses
            .iter()
            .enumerate()
            .filter(|(_, s)| **s != 0 && (spec.finned() || s.count_ones() <= spec.size))
            .fold(0, |b, (h, _)| b | (1 << h));
        let mut batch = Catalogue::default();
        for (mut base, mut cover) in [(ROWS, COLS), (COLS, ROWS)] {
            if spec.mutant() {
                base |= COLS;
                cover |= ROWS;
            }
            if spec.mixed() {
                base |= BOXES;
                cover |= BOXES;
            }
            let summary = (named || options.duals).then_some(&mut batch);
            let mut search = Search {
                fine: options.fine_scope.as_ref().zip(mode),
                spec,
                d: d as u8,
                positions,
                houses,
                covers: cover,
                template_del,
                poll: super::super::NodePoll::new(cancelled),
                named,
                min,
                max_fins,
                max_endo,
                one_fish: options.one_fish,
                catalogue: summary,
            };
            if let Some(first) = search.bases(base & eligible, spec.size, Selection::default()) {
                return vec![first];
            }
            if spec.mutant() {
                break;
            }
        }
        if options.duals {
            add_siamese(&mut batch.steps, cancelled);
            if cancelled() {
                return vec![];
            }
        }
        if let Some(kind) = mode {
            batch.steps.retain(|s| s.kind == kind);
            batch.steps.sort_by_key(order);
            if let Some(scope) = &options.fine_scope {
                for s in batch.steps.drain(..) {
                    if scope.might_match(&s) && !batch.proofs.contains(&s) {
                        batch.proofs.push(s);
                    }
                }
                batch.steps = batch.proofs;
            }
        }
        result.extend(batch.steps);
    }
    if !named && options.duals {
        result.sort_by_key(order);
    }
    result
}
pub(super) fn search(
    values: &[u8; 81],
    sets: &[u128; 10],
    spec: Spec,
    options: &Options,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    digit_search(values, sets, spec, options, None, cancelled)
        .into_iter()
        .next()
}
pub(super) fn catalogue(
    values: &[u8; 81],
    sets: &[u128; 10],
    requested: Spec,
    kind: &str,
    options: &Options,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    if !options.all_fish
        || requested.size < options.all_min_size
        || requested.size > options.all_max_size
    {
        return vec![];
    }
    let spec = Spec {
        class: [1, 4, 6][options.all_fish_type],
        size: options.all_max_size,
    };
    digit_search(values, sets, spec, options, Some(kind), cancelled)
}
