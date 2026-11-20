// SPDX-License-Identifier: GPL-3.0-or-later
use super::*;
use std::collections::HashMap;

#[derive(Clone, Copy)]
struct UsedLink {
    link: Link,
    active: u8,
}

impl UsedLink {
    fn active_digits(&self) -> [u8; 2] {
        [
            if self.active & 1 != 0 {
                self.link.first
            } else {
                0
            },
            if self.active & 2 != 0 {
                self.link.second
            } else {
                0
            },
        ]
    }
}
fn next_use(prior: UsedLink, link: Link) -> u8 {
    // RestrictedCommon.checkRC actually passes cand1 twice in its "both" branch.
    let excluded = if prior.active == 2 {
        prior.link.second
    } else {
        prior.link.first
    };
    if link.second == 0 {
        return u8::from(link.first != excluded);
    }
    if excluded == link.second {
        1
    } else if excluded == link.first {
        2
    } else {
        3
    }
}
struct Paths<'a> {
    groups: &'a [Als],
    outgoing: Vec<Vec<Link>>,
    path: Vec<UsedLink>,
    choices: Vec<Step>,
    only_one_per_step: bool,
    retain_all: bool,
    fine: Option<&'a dyn Fn(&Step) -> bool>,
    max_links: usize,
    keys: HashMap<Vec<(u8, u8)>, usize>,
    poll: super::super::NodePoll<'a>,
}
fn java_sum(step: &Step) -> i32 {
    step.deletes
        .iter()
        .enumerate()
        .map(|(n, &(cell, d))| i32::from(cell) * (1 + 80 * n as i32) + i32::from(d))
        .sum()
}
impl Paths<'_> {
    fn visit(&mut self, current: usize, prior: Option<UsedLink>) {
        if self.path.len() >= self.max_links {
            return;
        }
        for i in 0..self.outgoing[current].len() {
            if self.poll.cancelled() {
                return;
            }
            let link = self.outgoing[current][i];
            if self.path.first().is_some_and(|p| p.link.a == link.b)
                || self.path.iter().any(|p| p.link.b == link.b)
            {
                continue;
            }
            let active = prior.map_or(1, |p| next_use(p, link));
            if active == 0 {
                continue;
            }
            let options = if prior.is_none() && link.second != 0 {
                2
            } else {
                1
            };
            for pass in 0..options {
                let edge = UsedLink {
                    link,
                    active: if pass == 0 { active } else { 2 },
                };
                self.path.push(edge);
                if self.path.len() >= 3 {
                    self.evaluate();
                }
                self.visit(link.b, Some(edge));
                self.path.pop();
            }
        }
    }
    fn evaluate(&mut self) {
        let first = self.path[0];
        let Some(last) = self.path.last() else {
            return;
        };
        let mut exclude = [0; 4];
        exclude[..2].copy_from_slice(&first.active_digits());
        exclude[2..].copy_from_slice(&last.active_digits());
        let mut step = Step {
            kind: "ALS_XY_CHAIN",
            ..Step::default()
        };
        let start = &self.groups[first.link.a];
        eliminations(start, &self.groups[last.link.b], &exclude, &mut step);
        if step.deletes.is_empty() {
            return;
        }
        step.deletes.sort_by_key(|&(c, d)| (d, c));
        step.deletes.dedup();
        let rank = start.cells.count_ones() as usize
            + self
                .path
                .iter()
                .map(|p| self.groups[p.link.b].cells.count_ones() as usize)
                .sum::<usize>();
        let grouped = self.only_one_per_step || !self.retain_all;
        let existing = if grouped {
            self.keys.get(&step.deletes).copied()
        } else {
            None
        };
        if let Some(i) = existing {
            let earlier = &self.choices[i];
            // getCandidateString chooses the smallest total number of ALS cells.
            // When all equivalent proofs are kept, AlsComparator first ranks
            // the number of ALS and then their total number of cells.
            let better = if self.only_one_per_step {
                rank < cell_count(earlier)
            } else {
                (self.path.len() + 1, rank) < (earlier.alses.len(), cell_count(earlier))
            };
            if !better {
                return;
            }
        }
        start.record(&mut step);
        for edge in &self.path {
            let p = edge.link;
            let (a, b) = (&self.groups[p.a], &self.groups[p.b]);
            b.record(&mut step);
            step.restricted
                .push((p.a, p.b, p.first, p.second, edge.active));
            for d in edge.active_digits() {
                draw_link(a, b, d, true, &mut step);
            }
        }
        if self.fine.is_some_and(|accept| !accept(&step)) {
            return;
        }
        if let Some(i) = existing {
            self.choices[i] = step;
        } else {
            if grouped {
                self.keys.insert(step.deletes.clone(), self.choices.len());
            }
            self.choices.push(step);
        }
    }
}
pub(super) fn search(
    groups: &[Als],
    links: &[Link],
    only_one_per_step: bool,
    retain_all: bool,
    max_links: usize,
    fine: Option<&dyn Fn(&Step) -> bool>,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    let mut outgoing = vec![Vec::new(); groups.len()];
    for &link in links {
        outgoing[link.a].push(link);
    }
    let mut search = Paths {
        groups,
        outgoing,
        path: Vec::new(),
        choices: Vec::new(),
        only_one_per_step,
        retain_all,
        fine,
        max_links,
        keys: HashMap::new(),
        poll: super::super::NodePoll::new(cancelled),
    };
    for i in 0..groups.len() {
        if cancelled() {
            return vec![];
        }
        search.visit(i, None);
    }
    if retain_all {
        search.choices
    } else {
        search
            .choices
            .into_iter()
            .min_by_key(|step| (std::cmp::Reverse(step.deletes.len()), java_sum(step)))
            .into_iter()
            .collect()
    }
}

struct Flower<'a, 'b> {
    accept: &'b mut dyn FnMut(Step) -> Option<Step>,
    stem: u8,
    positions: &'a [u128; 10],
    groups: &'a [Als],
    petals: Vec<(u8, Vec<usize>)>,
    chosen: Vec<(u8, usize)>,
    overlap: bool,
    cancelled: &'a dyn Fn() -> bool,
}
impl Flower<'_, '_> {
    fn visit(&mut self, used: u128, shared: u16) -> Option<Step> {
        if (self.cancelled)() {
            return None;
        }
        let depth = self.chosen.len();
        if depth == self.petals.len() {
            let mut step = Step {
                kind: "DEATH_BLOSSOM",
                indices: vec![self.stem],
                ..Step::default()
            };
            for digit in digits(shared) {
                let d = usize::from(digit);
                let instances = self
                    .chosen
                    .iter()
                    .fold(0, |set, (_, id)| set | self.groups[*id].inside[d]);
                let targets =
                    buddies(instances) & self.positions[d] & !used & !(1u128 << self.stem);
                step.deletes.extend(pairs(targets, digit));
            }
            if step.deletes.is_empty() {
                return None;
            }
            for &(d, id) in &self.chosen {
                let a = &self.groups[id];
                step.fins.extend(pairs(a.inside[usize::from(d)], d));
                step.fins.push((self.stem, d));
                a.record(&mut step);
                step.restricted.push((0, 0, d, 0, 1));
            }
            return (self.accept)(step);
        }
        let d = self.petals[depth].0;
        for i in 0..self.petals[depth].1.len() {
            let id = self.petals[depth].1[i];
            let a = &self.groups[id];
            if !self.overlap && used & a.cells != 0 || shared & a.mask == 0 {
                continue;
            }
            self.chosen.push((d, id));
            let found = self.visit(used | a.cells, shared & a.mask);
            self.chosen.pop();
            if found.is_some() {
                return found;
            }
        }
        None
    }
}
pub(super) fn blossom(
    masks: &[u16; 81],
    groups: &[Als],
    overlap: bool,
    accept: &mut dyn FnMut(Step) -> Option<Step>,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    let positions = digit_sets(masks);
    for (stem, &mask) in masks.iter().enumerate() {
        if cancelled() {
            return None;
        }
        if mask == 0 {
            continue;
        }
        let petals: Vec<_> = digits(mask)
            .map(|d| {
                // RCForDeathBlossom uses a capacity of 100 ALS for each stem candidate.
                (
                    d,
                    groups
                        .iter()
                        .enumerate()
                        .filter(|(_, a)| a.outside[usize::from(d)] & (1 << stem) != 0)
                        .map(|(i, _)| i)
                        .take(100)
                        .collect::<Vec<_>>(),
                )
            })
            .collect();
        if petals.iter().any(|(_, ids)| ids.is_empty()) {
            continue;
        }
        let mut flower = Flower {
            accept,
            stem: stem as u8,
            positions: &positions,
            groups,
            petals,
            chosen: Vec::new(),
            overlap,
            cancelled,
        };
        // Adding petals only intersects their masks. A digit in the stem
        // can never be eliminated, so discard those branches before descent.
        if let Some(step) = flower.visit(0, 511 & !mask) {
            return Some(step);
        }
    }
    None
}
