// SPDX-License-Identifier: GPL-3.0-or-later
// HoDoKu ChainSolver: the house/endpoint order also decides which of two
// otherwise equivalent proofs is kept by the stable SolutionStep sort.
use super::{candidates, cells, digits, houses, Step, PEERS, UNITS};
use std::cmp::Reverse;
use std::collections::HashMap;

#[derive(Clone, Copy)]
struct Link {
    cell: u8,
    digit: u8,
    strong: bool,
}
impl Link {
    fn entry(self) -> i32 {
        (self.cell as i32) << 5 | i32::from(self.strong) << 4 | self.digit as i32
    }
}
fn links(masks: &[u16; 81], sets: &[u128; 10], kind: &str) -> Vec<Vec<Link>> {
    let within = matches!(kind, "REMOTE_PAIR" | "XY_CHAIN");
    let mut graph = vec![Vec::new(); 810];
    for (c, &mask) in masks.iter().enumerate() {
        if within && mask.count_ones() != 2 {
            continue;
        }
        for d in digits(mask) {
            let dst = &mut graph[c * 10 + d as usize];
            if within {
                dst.push(Link {
                    cell: c as u8,
                    digit: (mask ^ (1 << (d - 1))).trailing_zeros() as u8 + 1,
                    strong: true,
                });
            }
            for (axis, &unit) in houses(c).iter().enumerate() {
                let members = UNITS[unit] & sets[d as usize];
                let strong = !within && members.count_ones() == 2;
                for other in cells(members & !(1u128 << c)) {
                    let o = other as usize;
                    if axis == 2 && (c / 9 == o / 9 || c % 9 == o % 9)
                        || within && masks[o].count_ones() != 2
                        || kind == "REMOTE_PAIR" && masks[o] != mask
                    {
                        continue;
                    }
                    dst.push(Link {
                        cell: other,
                        digit: d,
                        strong,
                    });
                }
            }
        }
    }
    graph
}

struct Search<'a> {
    kind: &'static str,
    cancelled: &'a dyn Fn() -> bool,
    graph: Vec<Vec<Link>>,
    sets: &'a [u128; 10],
    path: Vec<Link>,
    max_len: usize,
    scope: Option<&'a super::FineScope>,
    all: Option<Vec<Step>>,
    shortest: HashMap<Vec<(u8, u8)>, usize>,
    best: Option<Step>,
    best_key: (Reverse<usize>, usize, usize),
}
impl Search<'_> {
    fn consider(&mut self, last: Link) {
        let first = self.path[0];
        let common = PEERS[first.cell as usize] & PEERS[last.cell as usize];
        let primary = self.sets[first.digit as usize] & common;
        if primary == 0 {
            return;
        }
        let mut values = vec![first.digit];
        let mut deletes = candidates(primary, first.digit);
        if self.kind == "REMOTE_PAIR" {
            let second = self.path[1].digit;
            values.push(second);
            let mut crossed = common;
            for i in (0..self.path.len()).step_by(2) {
                for j in (i + 6..self.path.len()).step_by(4) {
                    crossed |=
                        PEERS[self.path[i].cell as usize] & PEERS[self.path[j].cell as usize];
                }
            }
            deletes = candidates(crossed & self.sets[first.digit as usize], first.digit);
            deletes.extend(candidates(crossed & self.sets[second as usize], second));
            // getCandidateString() sorts in place before copying a non-Turbot step.
            deletes.sort_by_key(|&(c, d)| (d, c));
        }
        let weight = deletes
            .iter()
            .enumerate()
            .map(|(i, &(c, d))| (1 + 80 * i) * c as usize + d as usize)
            .sum();
        let key = (Reverse(deletes.len()), self.path.len(), weight);
        let step = || Step {
            kind: self.kind,
            values,
            deletes: deletes.clone(),
            chains: vec![self.path.iter().map(|l| l.entry()).collect()],
            ..Default::default()
        };
        if let Some(all) = &mut self.all {
            if self.scope.is_none() && self.kind != "TURBOT_FISH" {
                // Java retains earlier longer proofs but declines equal/longer rediscoveries.
                let shortest = self.shortest.entry(deletes.clone()).or_insert(usize::MAX);
                if *shortest <= self.path.len() {
                    return;
                }
                *shortest = self.path.len();
            }
            let s = step();
            if self.scope.is_none_or(|scope| scope.might_match(&s)) {
                all.push(s);
            }
        } else if self.best.is_none() || key < self.best_key {
            self.best_key = key;
            self.best = Some(step());
        }
    }
    fn visit(&mut self, visited: u128) {
        if (self.cancelled)() {
            return;
        }
        let last = self.path[self.path.len() - 1];
        let start = self.path[0];
        let index = last.cell as usize * 10 + last.digit as usize;
        let strong = !last.strong;
        for i in 0..self.graph[index].len() {
            let mut next = self.graph[index][i];
            if strong && !next.strong {
                continue;
            }
            let bit = 1u128 << next.cell;
            let closed = visited & bit != 0;
            if closed && next.cell != start.cell {
                continue;
            }
            let within = matches!(self.kind, "REMOTE_PAIR" | "XY_CHAIN");
            if within && (strong != (next.cell == last.cell)) {
                continue;
            }
            next.strong = strong;
            self.path.push(next);
            let length = self.path.len() - 1;
            if strong && next.digit == start.digit && (self.kind != "REMOTE_PAIR" || length >= 7) {
                self.consider(next);
            }
            if !closed && length < self.max_len {
                self.visit(visited | (1u128 << last.cell));
            }
            self.path.pop();
        }
    }
}
pub(super) fn search(
    masks: &[u16; 81],
    sets: &[u128; 10],
    kind: &'static str,
    cancelled: &dyn Fn() -> bool,
    all: bool,
    limit: usize,
    scope: Option<&super::FineScope>,
) -> Vec<Step> {
    let mut search = Search {
        kind,
        cancelled,
        graph: links(masks, sets, kind),
        sets,
        path: Vec::with_capacity(21),
        max_len: if kind == "TURBOT_FISH" { 3 } else { limit },
        scope,
        all: all.then(Vec::new),
        shortest: HashMap::new(),
        best: None,
        best_key: (Reverse(0), 0, 0),
    };
    for (c, &mask) in masks.iter().enumerate() {
        for d in digits(mask) {
            let index = c * 10 + d as usize;
            for i in 0..search.graph[index].len() {
                let first = search.graph[index][i];
                if !first.strong
                    || matches!(kind, "XY_CHAIN" | "REMOTE_PAIR") && first.cell as usize != c
                {
                    continue;
                }
                search.path.clear();
                search.path.extend([
                    Link {
                        cell: c as u8,
                        digit: d,
                        strong: false,
                    },
                    first,
                ]);
                search.visit(1u128 << c);
            }
        }
    }
    if let Some(mut steps) = search.all {
        if scope.is_none() {
            steps.sort_by(super::catalogue::compare);
        }
        steps
    } else {
        search.best.into_iter().collect()
    }
}
