// SPDX-License-Identifier: GPL-3.0-or-later
// Ordered direct consequences of one assumption, including dependencies of simulated singles.
use super::graph::{cells, Graph, Reach};
use crate::board::{digits, houses};
use crate::hints::UNITS;
use crate::phase5::basic::BasicState;
use std::collections::HashMap;

struct Link {
    to: usize,
    parents: [usize; 5],
    distance: usize,
}
struct Local {
    capacity: usize,
    entries: Vec<Link>,
    by_node: HashMap<usize, usize>,
}
impl Local {
    fn new(capacity: usize) -> Self {
        Self {
            capacity,
            entries: Vec::new(),
            by_node: HashMap::new(),
        }
    }
    fn insert(&mut self, to: usize, mut parents: [usize; 5]) {
        if self.entries.len() == self.capacity || self.by_node.contains_key(&to) {
            return;
        }
        let distance = (self.entries.get(parents[0]).map_or(0, |e| e.distance) + 1) & 511;
        for i in 1..5 {
            if parents[i] > parents[0] {
                parents.swap(0, i);
            }
        }
        self.by_node.insert(to, self.entries.len());
        self.entries.push(Link {
            to,
            parents,
            distance,
        });
    }
    fn position(&self, n: usize) -> usize {
        self.by_node.get(&n).copied().unwrap_or(0)
    }
}

struct Simulation<'a> {
    graph: &'a Graph,
    ids: &'a [[usize; 10]; 81],
    original: &'a [u16; 81],
    state: BasicState,
    table: Local,
}
impl Simulation<'_> {
    fn set(&mut self, cell: usize, digit: u8, reason: Option<bool>) {
        let code = self.ids[cell][digit as usize] * 2 + 1;
        let candidates = self.state.masks[cell];
        let n = self.graph.node(code);
        let mut parents = [0; 5];
        match reason {
            Some(true) => {
                for (slot, d) in parents
                    .iter_mut()
                    .zip(digits(self.original[cell]).filter(|&d| d != digit))
                {
                    *slot = self.table.position(2 * self.ids[cell][d as usize]);
                }
            }
            Some(false) => {
                let h = houses(cell)
                    .into_iter()
                    .min_by_key(|&h| self.state.free_in_house(h, digit))
                    .unwrap();
                for (slot, c) in parents.iter_mut().zip(
                    UNITS[h]
                        .into_iter()
                        .filter(|&c| c != cell && self.original[c] >> (digit - 1) & 1 != 0),
                ) {
                    *slot = self.table.position(2 * self.ids[c][digit as usize]);
                }
            }
            None => {}
        }
        self.state.assume(cell, digit, true);
        let pos = self.table.entries.len();
        self.table.insert(code, parents);
        let mut parent = [0; 5];
        parent[0] = pos;
        for c in cells(n.buddies & self.graph.candidates[digit as usize]) {
            self.table.insert(2 * self.ids[c][digit as usize], parent);
        }
        for d in digits(candidates).filter(|&d| d != digit) {
            self.table.insert(2 * self.ids[cell][d as usize], parent);
        }
    }
}
pub(super) struct Tables {
    local: Vec<Local>,
}
pub(super) struct Expanded {
    pub reach: Reach,
    source: Vec<usize>,
}
impl Tables {
    pub fn build(
        graph: &Graph,
        values: &[u8; 81],
        masks: &[u16; 81],
        max_entries: usize,
        look_ahead: usize,
        cancelled: &dyn Fn() -> bool,
    ) -> Option<Self> {
        let mut local = Vec::with_capacity(graph.edges.len());
        let mut ids = [[0; 10]; 81];
        for (i, &n) in graph.nodes[..graph.ordinary].iter().enumerate() {
            ids[n.cell][n.digit as usize] = i;
        }
        let original = BasicState::new(values, masks);
        for s in 0..graph.edges.len() {
            if cancelled() {
                return None;
            }
            if s / 2 >= graph.ordinary {
                let mut t = Local::new(max_entries);
                t.insert(s, [0; 5]);
                for &e in &graph.edges[s] {
                    t.insert(e, [0; 5]);
                    if let Some(entry) = t.entries.last_mut() {
                        entry.distance += graph.penalty(s, e);
                    }
                }
                local.push(t);
                continue;
            }
            let mut sim = Simulation {
                graph,
                ids: &ids,
                original: masks,
                state: original.clone(),
                table: Local::new(max_entries),
            };
            let n = graph.node(s);
            if s % 2 == 1 {
                sim.set(n.cell, n.digit, None);
            } else {
                sim.state.assume(n.cell, n.digit, false);
                sim.table.insert(s, [0; 5]);
                let m = sim.state.masks[n.cell];
                if m.count_ones() == 1 {
                    sim.set(n.cell, m.trailing_zeros() as u8 + 1, None);
                }
            }
            for _ in 0..look_ahead {
                let mut singles = sim.state.catalogue("NAKED_SINGLE");
                singles.extend(sim.state.catalogue("HIDDEN_SINGLE"));
                if singles.is_empty() {
                    break;
                }
                for step in singles {
                    sim.set(
                        step.indices[0] as usize,
                        step.values[0],
                        Some(step.kind == "NAKED_SINGLE"),
                    );
                }
            }
            for &e in &graph.edges[s] {
                if e / 2 >= graph.ordinary {
                    sim.table.insert(e, [0; 5]);
                }
            }
            local.push(sim.table);
        }
        Some(Self { local })
    }
    pub fn expand(&self, start: usize, limit: usize) -> Expanded {
        let mut previous = vec![usize::MAX; self.local.len()];
        let mut distance = vec![0; self.local.len()];
        let mut source = vec![usize::MAX; self.local.len()];
        let mut queue = vec![];
        for link in &self.local[start].entries {
            queue.push(link.to);
            previous[link.to] = start;
            source[link.to] = start;
            distance[link.to] = link.distance;
        }
        let mut i = 1;
        while i < queue.len() && queue.len() < limit {
            let from = queue[i];
            i += 1;
            for e in &self.local[from].entries[1..] {
                let d = (distance[from] + e.distance) & 511;
                if previous[e.to] == usize::MAX {
                    queue.push(e.to);
                    previous[e.to] = from;
                    source[e.to] = from;
                    distance[e.to] = d;
                    if queue.len() == limit {
                        break;
                    }
                } else if source[e.to] != start && distance[e.to] > d {
                    previous[e.to] = from;
                    source[e.to] = from;
                    distance[e.to] = d;
                }
            }
        }
        Expanded {
            reach: Reach { queue, previous },
            source,
        }
    }
    fn walk(
        &self,
        expanded: &Expanded,
        start: usize,
        end: usize,
        main: (&[usize], u128),
        g: &Graph,
        others: &mut Vec<usize>,
    ) -> Vec<usize> {
        let (stop, stop_cells) = main;
        let mut rev = vec![end];
        let mut current = end;
        while current != start && rev.len() < 1000 {
            let from = expanded.source[current];
            let local = &self.local[from];
            let mut index = local.position(current);
            while index > 0 && rev.len() < 1000 {
                let parents = local.entries[index].parents;
                index = parents[0];
                if index >= local.entries.len() {
                    return rev;
                }
                current = local.entries[index].to;
                rev.push(current);
                if !stop.is_empty()
                    && stop_cells & (1 << g.node(current).cell) != 0
                    && stop.contains(&current)
                {
                    return rev;
                }
                if stop.is_empty() {
                    for &p in &parents[1..] {
                        if p > 0 && p < local.entries.len() {
                            others.push(local.entries[p].to);
                        }
                    }
                }
            }
            if index == 0 && from != current {
                break;
            }
        }
        rev
    }
    pub fn proof(&self, g: &Graph, r: &Expanded, start: usize, end: usize) -> Vec<i32> {
        let mut others = vec![];
        let main = self.walk(r, start, end, (&[], 0), g, &mut others);
        let stop_cells = main.iter().skip(1).fold(0, |s, &n| s | g.node(n).cells);
        let branches: Vec<_> = others
            .into_iter()
            .map(|n| self.walk(r, start, n, (&main, stop_cells), g, &mut vec![]))
            .collect();
        let mut chain = vec![];
        for &n in main.iter().rev() {
            chain.push(g.code(n));
            for branch in branches.iter().filter(|p| p.last() == Some(&n)) {
                chain.extend(branch.iter().rev().skip(1).map(|&n| -g.code(n)));
                chain.push(i32::MIN);
            }
        }
        chain
    }
}
