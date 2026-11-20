// SPDX-License-Identifier: GPL-3.0-or-later
// Contradictions and common consequences, in the traversal order of TablingSolver.
use super::graph::{cell_set, cells, Graph, Reach};
use super::net::{Expanded, Tables};
use super::{Options, Step};
use crate::board::digits;
use crate::hints::UNITS;
use std::collections::HashMap;

struct Outcome<'a> {
    graph: &'a Graph,
    reaches: Vec<Reach>,
    sets: Vec<[[u128; 10]; 2]>,
    best: Option<Step>,
    net: Option<Tables>,
    expanded: Vec<Expanded>,
    entity: Option<(u8, i16)>,
    all: bool,
    only_one: bool,
    predicate: Option<&'a dyn Fn(&Step) -> bool>,
    list: Vec<Step>,
    by_conclusion: HashMap<(usize, &'static str), usize>,
}

impl Outcome<'_> {
    fn consider(&mut self, mut kind: &'static str, signed: usize, routes: &[(usize, usize)]) {
        let n = self.graph.node(signed);
        let placing = signed % 2 == 1;
        if let Some(prev) = &self.best {
            let key = if placing {
                (false, n.cell, 0)
            } else {
                (true, n.cell, n.digit)
            };
            let old = if let Some(&c) = prev.indices.first() {
                (false, c as usize, 0)
            } else {
                (true, prev.deletes[0].0 as usize, prev.deletes[0].1)
            };
            if key > old {
                return;
            }
        }
        let chains: Vec<Vec<i32>> = routes
            .iter()
            .map(|&(s, e)| {
                if let Some(net) = &self.net {
                    net.proof(self.graph, &self.expanded[s], s, e)
                } else {
                    self.reaches[s]
                        .path(e)
                        .into_iter()
                        .map(|n| self.graph.code(n))
                        .collect()
                }
            })
            .collect();
        if self.net.is_some() {
            if !chains.iter().flatten().any(|&e| e < 0) {
                return;
            }
            kind = if kind.ends_with("VERITY") {
                "FORCING_NET_VERITY"
            } else {
                "FORCING_NET_CONTRADICTION"
            };
        }
        let mut step = Step {
            kind,
            entity: if kind.ends_with("CONTRADICTION") {
                self.entity
            } else {
                None
            },
            chains,
            ..Step::default()
        };
        if placing {
            step.indices.push(n.cell as u8);
            step.values.push(n.digit);
        } else {
            step.deletes.push((n.cell as u8, n.digit));
        }
        self.graph.adjust(&mut step);
        if let Some(prev) = &self.best {
            let same = (placing && prev.indices.first().is_some_and(|&c| c as usize == n.cell))
                || (!placing && prev.deletes.first() == Some(&(n.cell as u8, n.digit)));
            if same && placing && prev.kind != kind {
                return;
            }
            if same && length(&step) >= length(prev) {
                return;
            }
        }
        if self.all {
            if let Some(matches) = self.predicate {
                if matches(&step) {
                    self.list.push(step)
                }
                return;
            }
            if self.only_one {
                let index = *self
                    .by_conclusion
                    .entry((signed, kind))
                    .or_insert(self.list.len());
                if let Some(old) = self.list.get_mut(index) {
                    if length(&step) < length(old) {
                        *old = step;
                    }
                    return;
                }
            }
            self.list.push(step);
        } else {
            self.best = Some(step);
        }
    }
    fn contradiction(&mut self, start: usize, ends: impl IntoIterator<Item = usize>) {
        let routes: Vec<_> = ends.into_iter().map(|e| (start, e)).collect();
        self.consider("FORCING_CHAIN_CONTRADICTION", start ^ 1, &routes)
    }
    fn verities(&mut self, sources: &[usize], exclude: u128, ids: &[[usize; 10]; 81]) {
        if sources.is_empty() {
            return;
        }
        let mut common = self.sets[sources[0]];
        for &s in &sources[1..] {
            for sign in 0..2 {
                for d in 1..=9 {
                    common[sign][d] &= self.sets[s][sign][d];
                }
            }
        }
        for d in 1..=9 {
            for sign in [1, 0] {
                for c in cells(common[sign][d] & !exclude) {
                    let end = 2 * ids[c][d] + sign;
                    let paths: Vec<_> = sources.iter().map(|&s| (s, end)).collect();
                    self.consider("FORCING_CHAIN_VERITY", end, &paths);
                }
            }
        }
    }
}

fn length(s: &Step) -> usize {
    super::graph::length(s)
}
struct Order<'a> {
    step: &'a Step,
    length: usize,
}
impl crate::hints::catalogue_order::CatalogueOrder for Order<'_> {
    fn cmp(&self, rhs: &Self) -> std::cmp::Ordering {
        use std::cmp::Ordering::*;
        let (a, b) = (self.step, rhs.step);
        match (a.indices.first(), b.indices.first()) {
            (Some(_), None) => Less,
            (None, Some(_)) => Greater,
            (Some(x), Some(y)) => {
                if a.kind != b.kind || x != y {
                    if x < y {
                        Less
                    } else {
                        Greater
                    }
                } else {
                    self.length.cmp(&rhs.length)
                }
            }
            (None, None) => a
                .deletes
                .cmp(&b.deletes)
                .then_with(|| self.length.cmp(&rhs.length)),
        }
    }
}
pub(super) fn search(
    values: &[u8; 81],
    masks: &[u16; 81],
    g: &Graph,
    kind: &str,
    options: &Options,
    query: super::Query<'_>,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    let net = kind.starts_with("FORCING_NET");
    let all = !matches!(query, super::Query::First);
    let predicate = query.predicate();
    let mut ids = [[0; 10]; 81];
    let house = UNITS.map(|u| u.into_iter().fold(0, |s, c| s | cell_set(c)));
    let mut allowed = [0u128; 10];
    for (i, &n) in g.nodes[..g.ordinary].iter().enumerate() {
        ids[n.cell][n.digit as usize] = i;
    }
    for c in 0..81 {
        if values[c] == 0 {
            let legal = crate::board::houses(c)
                .into_iter()
                .flat_map(|h| UNITS[h])
                .fold(511u16, |mask, p| {
                    if values[p] == 0 {
                        mask
                    } else {
                        mask & !(1 << (values[p] - 1))
                    }
                });
            for d in digits(legal) {
                allowed[d as usize] |= cell_set(c);
            }
        }
    }
    let mut o = Outcome {
        graph: g,
        reaches: vec![],
        sets: vec![],
        best: None,
        all,
        only_one: options.only_one_chain,
        predicate,
        list: vec![],
        by_conclusion: HashMap::new(),
        net: if net {
            {
                let Some(tables) = Tables::build(
                    g,
                    values,
                    masks,
                    options.max_entries,
                    options.look_ahead,
                    cancelled,
                ) else {
                    return vec![];
                };
                Some(tables)
            }
        } else {
            None
        },
        expanded: vec![],
        entity: None,
    };
    for start in 0..g.ordinary * 2 {
        if cancelled() {
            return vec![];
        }
        let ordinary;
        let reach = if let Some(tables) = &o.net {
            o.expanded.push(tables.expand(start, options.max_entries));
            &o.expanded.last().unwrap().reach
        } else {
            ordinary = g.reachable(start, options.max_entries);
            o.reaches.push(ordinary);
            o.reaches.last().unwrap()
        };
        let mut set = [[0; 10]; 2];
        for &e in &reach.queue {
            if e / 2 < g.ordinary {
                let n = g.node(e);
                set[e % 2][n.digit as usize] |= n.cells;
            }
        }
        o.sets.push(set);
    }
    let mut scratch = g.scratch_first;
    for id in 0..g.ordinary {
        for start in [id * 2 + 1, id * 2] {
            if cancelled() {
                return vec![];
            }
            let s = o.sets[start];
            let reach = if net {
                &o.expanded[start].reach
            } else {
                &o.reaches[start]
            };
            if reach.previous[start ^ 1] != usize::MAX {
                o.entity = Some((3, scratch));
                o.contradiction(start, [start ^ 1]);
            }
            for d in 1..=9 {
                if let Some(c) = cells(s[0][d] & s[1][d]).next() {
                    scratch = c as i16;
                    o.entity = Some((3, scratch));
                    o.contradiction(start, [2 * ids[c][d], 2 * ids[c][d] + 1]);
                }
            }
            for a in 1..=9 {
                for b in a + 1..=9 {
                    if let Some(c) = cells(s[1][a] & s[1][b]).next() {
                        scratch = c as i16;
                        o.entity = Some((3, scratch));
                        o.contradiction(start, [2 * ids[c][a] + 1, 2 * ids[c][b] + 1]);
                    }
                }
            }
            for base in [0, 9, 18] {
                for d in 1..=9 {
                    for (num, &h) in house[base..base + 9].iter().enumerate() {
                        let common = s[1][d] & h;
                        if common != 0 {
                            scratch = common.trailing_zeros() as i16;
                        }
                        if common.count_ones() > 1 {
                            o.entity = Some(([1, 2, 0][base / 9], num as i16));
                            o.contradiction(start, cells(common).map(|c| 2 * ids[c][d] + 1));
                        }
                    }
                }
            }
            for c in 0..81 {
                if masks[c] != 0
                    && digits(masks[c]).all(|d| s[0][d as usize] & cell_set(c) != 0)
                    && s[1].iter().all(|set| set & cell_set(c) == 0)
                {
                    o.entity = Some((3, c as i16));
                    o.contradiction(start, digits(masks[c]).map(|d| 2 * ids[c][d as usize]));
                }
            }
            for base in [0, 9, 18] {
                for d in 1..=9 {
                    for (num, &h) in house[base..base + 9].iter().enumerate() {
                        let all = h & allowed[d];
                        if all != 0 && all & !s[0][d] == 0 {
                            scratch = all.trailing_zeros() as i16;
                            o.entity = Some(([1, 2, 0][base / 9], num as i16));
                            o.contradiction(start, cells(all).map(|c| 2 * ids[c][d]));
                        }
                    }
                }
            }
            if let Some(c) = cells(house[26] & allowed[9]).next() {
                scratch = c as i16;
            }
        }
    }
    for (id, n) in g.nodes[..g.ordinary].iter().enumerate() {
        if cancelled() {
            return vec![];
        }
        o.verities(&[id * 2 + 1, id * 2], n.cells, &ids);
    }
    for c in 0..81 {
        if cancelled() {
            return vec![];
        }
        let all: Vec<_> = digits(masks[c])
            .map(|d| ids[c][d as usize] * 2 + 1)
            .collect();
        o.verities(&all, 0, &ids);
    }
    for h in house {
        if cancelled() {
            return vec![];
        }
        for d in 1..=9 {
            let all: Vec<_> = cells(h & g.candidates[d])
                .map(|c| ids[c][d] * 2 + 1)
                .collect();
            o.verities(&all, 0, &ids);
        }
    }
    if !all {
        return o.best.into_iter().collect();
    }
    if predicate.is_some() {
        o.list.retain(|s| super::named(kind, s.kind));
        return o.list;
    }
    let mut ranked = Vec::with_capacity(o.list.len());
    for group in o.list.chunks(64) {
        if cancelled() {
            return vec![];
        }
        ranked.extend(group.iter().map(|step| Order {
            step,
            length: length(step),
        }));
    }
    let order = crate::hints::catalogue_order::ordered_runs(&ranked);
    let mut sorted = Vec::new();
    for group in order.chunks(64) {
        if cancelled() {
            return vec![];
        }
        for &i in group {
            if super::named(kind, o.list[i].kind) {
                sorted.push(std::mem::take(&mut o.list[i]));
            }
        }
    }
    sorted
}
