// SPDX-License-Identifier: GPL-3.0-or-later
// Ordered direct implications from HoDoKu GroupNode and TablingSolver.
use crate::board::{digits, houses};
use crate::hints::UNITS;
use crate::phase5::{
    als::{self, Als},
    Step,
};

pub(super) fn cell_set(cell: usize) -> u128 {
    1 << cell
}
pub(super) fn cells(set: u128) -> impl Iterator<Item = usize> {
    let mut bits = set;
    std::iter::from_fn(move || {
        if bits == 0 {
            return None;
        }
        let c = bits.trailing_zeros() as usize;
        bits &= bits - 1;
        Some(c)
    })
}
#[derive(Clone, Copy)]
pub(super) struct Node {
    pub cell: usize,
    pub digit: u8,
    pub cells: u128,
    pub buddies: u128,
    pub code: i32,
    pub als: Option<usize>,
    line: usize,
    block: usize,
}
pub(super) struct Graph {
    pub nodes: Vec<Node>,
    pub edges: Vec<Vec<usize>>,
    pub ordinary: usize,
    pub candidates: [u128; 10],
    pub alses: Vec<Als>,
    pub scratch_first: i16,
}
pub(super) struct Reach {
    pub queue: Vec<usize>,
    pub previous: Vec<usize>,
}
impl Graph {
    pub fn new(masks: &[u16; 81], grouped: bool) -> Self {
        let house = UNITS.map(|unit| unit.into_iter().fold(0, |acc, c| acc | cell_set(c)));
        let buddies = std::array::from_fn::<_, 81, _>(|c| {
            houses(c).into_iter().fold(0, |acc, h| acc | house[h]) & !cell_set(c)
        });
        let mut graph = Self {
            nodes: vec![],
            edges: vec![],
            ordinary: 0,
            candidates: [0; 10],
            alses: vec![],
            scratch_first: 0,
        };
        let mut ids = [[0usize; 10]; 81];
        for c in 0..81 {
            for d in digits(masks[c]) {
                ids[c][d as usize] = graph.nodes.len();
                graph.nodes.push(Node {
                    cell: c,
                    digit: d,
                    cells: cell_set(c),
                    buddies: buddies[c],
                    code: ((c as i32) << 5) | i32::from(d),
                    als: None,
                    line: 27,
                    block: houses(c)[2],
                });
                graph.candidates[d as usize] |= cell_set(c);
            }
        }
        graph.ordinary = graph.nodes.len();
        if grouped {
            for line in 0..18 {
                for digit in 1u8..=9 {
                    let line_cells = house[line] & graph.candidates[digit as usize];
                    for (block, &block_cells) in house.iter().enumerate().skip(18) {
                        let members = line_cells & block_cells;
                        if members.count_ones() < 2 {
                            continue;
                        }
                        let mut parts = cells(members);
                        let first = parts.next().unwrap();
                        let second = parts.next().unwrap();
                        let third = parts.next().unwrap_or(127);
                        let code = 1 << 26
                            | (third as i32) << 19
                            | (second as i32) << 12
                            | (first as i32) << 5
                            | i32::from(digit);
                        let common = cells(members).fold(u128::MAX, |acc, c| acc & buddies[c]);
                        graph.nodes.push(Node {
                            cell: first,
                            digit,
                            cells: members,
                            buddies: common,
                            code,
                            als: None,
                            line,
                            block,
                        });
                    }
                }
            }
        }
        graph.edges.resize_with(graph.nodes.len() * 2, Vec::new);
        for id in 0..graph.ordinary {
            let n = graph.nodes[id];
            for d in digits(masks[n.cell]).filter(|&d| d != n.digit) {
                let other = ids[n.cell][d as usize];
                graph.edge(id, true, other, false);
                if masks[n.cell].count_ones() == 2 {
                    graph.edge(id, false, other, true);
                }
            }
            for h in houses(n.cell) {
                let others = house[h] & graph.candidates[n.digit as usize] & !n.cells;
                for c in cells(others) {
                    graph.edge(id, true, ids[c][n.digit as usize], false);
                }
                if others.count_ones() == 1 {
                    graph.edge(
                        id,
                        false,
                        ids[others.trailing_zeros() as usize][n.digit as usize],
                        true,
                    );
                }
            }
        }
        for id in graph.ordinary..graph.nodes.len() {
            let n = graph.nodes[id];
            let others = n.buddies & graph.candidates[n.digit as usize];
            if others != 0 {
                graph.scratch_first = others.trailing_zeros() as i16;
            }
            for c in cells(others) {
                let other = ids[c][n.digit as usize];
                graph.edge(id, true, other, false);
                graph.edge(other, true, id, false);
            }
            for h in [n.block, n.line] {
                let extra = house[h] & others;
                if extra.count_ones() == 1 {
                    let other = ids[extra.trailing_zeros() as usize][n.digit as usize];
                    graph.edge(id, false, other, true);
                    graph.edge(other, false, id, true);
                }
            }
            let mut neighbors = [Vec::new(), Vec::new()];
            for other in graph.ordinary..graph.nodes.len() {
                let m = graph.nodes[other];
                if m.digit != n.digit || m.cells & n.cells != 0 {
                    continue;
                }
                for (i, same) in [m.line == n.line, m.block == n.block]
                    .into_iter()
                    .enumerate()
                {
                    if same {
                        neighbors[i].push(other);
                        graph.edge(id, true, other, false);
                    }
                }
            }
            let mut residual = others;
            for (h, near) in [n.line, n.block].into_iter().zip(neighbors) {
                if let [other] = near[..] {
                    residual = house[h]
                        & graph.candidates[n.digit as usize]
                        & !(n.cells | graph.nodes[other].cells);
                    if residual == 0 {
                        graph.edge(id, false, other, true);
                    }
                }
            }
            if id + 1 == graph.nodes.len() && residual != 0 {
                graph.scratch_first = residual.trailing_zeros() as i16;
            }
        }
        graph
    }
    pub fn include_als(&mut self, masks: &[u16; 81], cancelled: &dyn Fn() -> bool) {
        let groups = als::all(masks, &self.candidates, cancelled);
        let group_end = self.nodes.len();
        let mut ordinary = [[0usize; 10]; 81];
        for (i, n) in self.nodes[..self.ordinary].iter().enumerate() {
            ordinary[n.cell][n.digit as usize] = i;
        }
        let mut nodes = vec![[usize::MAX; 10]; groups.len()];
        for (i, a) in groups.iter().enumerate() {
            for digit in digits(a.mask) {
                let d = digit as usize;
                let cell = a.inside[d].trailing_zeros() as usize;
                let code = (2 << 26)
                    | ((i as i32 & 16383) << 12)
                    | ((cell as i32) << 5)
                    | i32::from(digit);
                nodes[i][d] = self.nodes.len();
                self.nodes.push(Node {
                    cell,
                    digit,
                    cells: a.cells,
                    buddies: a.outside[d],
                    code,
                    line: 27,
                    block: 27,
                    als: Some(i),
                });
            }
        }
        self.edges.resize_with(self.nodes.len() * 2, Vec::new);
        for (i, a) in groups.iter().enumerate() {
            if cancelled() {
                break;
            }
            if a.cells.count_ones() == 1 {
                continue;
            }
            for digit in digits(a.mask) {
                let d = digit as usize;
                let id = nodes[i][d];
                let mut eliminates = a.outside;
                eliminates[d] = 0;
                let affected = eliminates.iter().fold(0, |s, c| s | c);
                if affected == 0 {
                    continue;
                }
                for cell in cells(a.outside[d]) {
                    self.edge(ordinary[cell][d], true, id, false);
                    for j in self.ordinary..group_end {
                        let n = self.nodes[j];
                        if n.digit == digit
                            && n.cells & cell_set(cell) != 0
                            && a.cells & n.cells == 0
                            && a.inside[d] & !n.buddies == 0
                        {
                            self.edge(j, true, id, false);
                        }
                    }
                }
                for k in 1..=9 {
                    for cell in cells(eliminates[k]) {
                        self.edge(id, false, ordinary[cell][k], false);
                    }
                    for j in self.ordinary..group_end {
                        let n = self.nodes[j];
                        if n.digit as usize == k && n.cells & !eliminates[k] == 0 {
                            self.edge(id, false, j, false);
                        }
                    }
                }
                for (j, b) in groups.iter().enumerate() {
                    if a.cells & b.cells != 0 {
                        continue;
                    }
                    for k in digits(b.mask) {
                        let k = k as usize;
                        if b.inside[k] & !eliminates[k] == 0 {
                            self.edge(id, false, nodes[j][k], false);
                        }
                    }
                }
                // Java iterates the union of all candidate buddies (including the entry digit).
                let all = a.outside.iter().fold(0, |s, c| s | c);
                for c in cells(all) {
                    if masks[c].count_ones() == 2 {
                        continue;
                    }
                    let mask = digits(masks[c])
                        .filter(|&k| eliminates[k as usize] & cell_set(c) == 0)
                        .fold(0u16, |m, k| m | (1 << (k - 1)));
                    if mask.count_ones() == 1 {
                        self.edge(
                            id,
                            false,
                            ordinary[c][mask.trailing_zeros() as usize + 1],
                            true,
                        );
                    }
                }
            }
        }
        self.alses = groups;
    }
    pub fn penalty(&self, from: usize, to: usize) -> usize {
        self.node(from).als.map_or(0, |id| {
            penalty(self.alses[id].mask.count_ones() as usize) + to % 2
        })
    }
    pub fn buddies_for(&self, who: usize, digit: u8) -> u128 {
        let n = self.node(who);
        n.als
            .map_or(n.buddies, |id| self.alses[id].outside[digit as usize])
    }
    pub fn adjust(&self, step: &mut Step) {
        let mut remap = std::collections::HashMap::new();
        for chain in &mut step.chains {
            for raw in chain {
                let code = raw.wrapping_abs();
                if (code >> 26) & 15 != 2 {
                    continue;
                }
                let old = ((code >> 12) & 16383) as usize;
                let id = *remap.entry(old).or_insert_with(|| {
                    let a = &self.alses[old];
                    let n = step.alses.len();
                    step.alses.push((
                        cells(a.cells).map(|c| c as u8).collect(),
                        digits(a.mask).collect(),
                    ));
                    n
                });
                *raw = (*raw & !(16383 << 12)) | ((id as i32) << 12);
            }
        }
    }
    fn edge(&mut self, from: usize, on: bool, to: usize, strong: bool) {
        let next = 2 * to + usize::from(strong);
        let edge = &mut self.edges[2 * from + usize::from(on)];
        if !edge.contains(&next) {
            edge.push(next);
        }
    }
    pub fn node(&self, signed: usize) -> Node {
        self.nodes[signed / 2]
    }
    pub fn code(&self, signed: usize) -> i32 {
        self.node(signed).code | if signed % 2 == 1 { 16 } else { 0 }
    }
    pub fn reachable(&self, start: usize, limit: usize) -> Reach {
        let mut previous = vec![usize::MAX; self.edges.len()];
        let mut queue = vec![start];
        previous[start] = start;
        let mut distance = vec![0; self.edges.len()];
        distance[start] = 1;
        let mut index = 0;
        while index < queue.len() && queue.len() < limit {
            let from = queue[index];
            index += 1;
            for &to in self.edges[from].iter().take(limit.saturating_sub(1)) {
                let cost = distance[from] + 2 + self.penalty(from, to);
                if previous[to] == usize::MAX {
                    distance[to] = cost;
                    queue.push(to);
                    previous[to] = from;
                    if queue.len() == limit {
                        break;
                    }
                } else if previous[to] != start && to != start && cost < distance[to] {
                    distance[to] = cost;
                    previous[to] = from;
                }
            }
        }
        Reach { previous, queue }
    }
}
impl Reach {
    pub fn path(&self, mut end: usize) -> Vec<usize> {
        let mut path = vec![end];
        while self.previous[end] != end {
            end = self.previous[end];
            path.push(end);
        }
        path.reverse();
        path
    }
}

pub(super) fn penalty(size: usize) -> usize {
    match size {
        0 | 1 => 0,
        2 => 1,
        _ => (size - 1) * 2,
    }
}
pub(super) fn length(step: &Step) -> usize {
    step.chains
        .iter()
        .flatten()
        .map(|raw| {
            let code = raw.wrapping_abs();
            if (code >> 26) & 15 == 2 {
                1 + step
                    .alses
                    .get(((code >> 12) & 16383) as usize)
                    .map_or(5, |a| penalty(a.0.len()))
            } else {
                1
            }
        })
        .sum()
}
