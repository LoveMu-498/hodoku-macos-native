// SPDX-License-Identifier: GPL-3.0-or-later
// Port of UserChainValidator.preview and NativeAlsStrongLinks from mac-app.
use crate::board::{digits, houses, Board};
use std::collections::{HashSet, VecDeque};

fn weak(a: &[u16], b: &[u16]) -> bool {
    a.iter().all(|&a| {
        b.iter().all(|&b| {
            let (x, y) = (usize::from(a / 10), usize::from(b / 10));
            a != b
                && (x == y || (a % 10 == b % 10 && houses(x).iter().any(|h| houses(y).contains(h))))
        })
    })
}

struct Sources {
    complete: Vec<Vec<u16>>,
    als: Option<Vec<(Vec<usize>, u16)>>,
}

impl Sources {
    fn new(board: &Board) -> Self {
        let mut complete = Vec::new();
        let mut units = vec![Vec::new(); 27 * 9];
        for (cell, &mask) in board.masks.iter().enumerate() {
            let atoms: Vec<u16> = digits(mask)
                .map(|d| cell as u16 * 10 + u16::from(d))
                .collect();
            if !atoms.is_empty() {
                for &atom in &atoms {
                    for h in houses(cell) {
                        units[h * 9 + usize::from(atom % 10 - 1)].push(atom);
                    }
                }
                complete.push(atoms);
            }
        }
        complete.extend(units.into_iter().filter(|unit| !unit.is_empty()));
        Self {
            complete,
            als: None,
        }
    }

    fn ordinary(&self, a: &[u16], b: &[u16]) -> bool {
        self.complete.iter().any(|unit| {
            unit.iter()
                .all(|x| a.binary_search(x).is_ok() || b.binary_search(x).is_ok())
        })
    }

    fn als(&mut self, board: &Board, a: &[u16], b: &[u16]) -> bool {
        let (d, e) = (a[0] % 10, b[0] % 10);
        if d == e || !a.iter().all(|x| x % 10 == d) || !b.iter().all(|x| x % 10 == e) {
            return false;
        }
        let all = self.als.get_or_insert_with(|| {
            let mut sets = Vec::new();
            for house in 0..27 {
                let cells: Vec<_> = (0..81)
                    .filter(|&c| board.values[c] == 0 && houses(c).contains(&house))
                    .collect();
                for subset in 1usize..(1 << cells.len()) {
                    let count = subset.count_ones();
                    if !(2..=8).contains(&count) {
                        continue;
                    }
                    let selected = cells
                        .iter()
                        .enumerate()
                        .filter(|(i, _)| subset & (1 << i) != 0)
                        .map(|(_, &c)| c);
                    let union = selected.clone().fold(0, |bits, c| bits | board.masks[c]);
                    if union.count_ones() == count + 1 {
                        sets.push((selected.collect(), union));
                    }
                }
            }
            sets
        });
        let matches = |cells: &[usize], digit: u16, atoms: &[u16]| {
            cells
                .iter()
                .copied()
                .filter(|&c| board.masks[c] & (1 << (digit - 1)) != 0)
                .map(|c| c as u16 * 10 + digit)
                .eq(atoms.iter().copied())
        };
        all.iter().any(|(cells, mask)| {
            mask & (1 << (d - 1)) != 0
                && mask & (1 << (e - 1)) != 0
                && matches(cells, d, a)
                && matches(cells, e, b)
        })
    }
}

fn connect(graph: &mut [Vec<usize>], a: usize, b: usize, strong: bool) {
    let from = usize::from(!strong);
    graph[2 * a + from].push(2 * b + (1 - from));
    graph[2 * b + from].push(2 * a + (1 - from));
}

fn proof(graph: &[Vec<usize>], start: usize) -> Option<Vec<usize>> {
    let goal = start ^ 1;
    let mut parent = vec![usize::MAX; graph.len()];
    let mut queue = VecDeque::from([start]);
    parent[start] = start;
    while let Some(at) = queue.pop_front() {
        for &next in &graph[at] {
            if parent[next] != usize::MAX {
                continue;
            }
            parent[next] = at;
            if next == goal {
                let mut path = vec![goal];
                while *path.last().unwrap() != start {
                    path.push(parent[*path.last().unwrap()]);
                }
                path.reverse();
                return Some(path);
            }
            queue.push_back(next);
        }
    }
    None
}

#[derive(Default)]
pub struct Analysis {
    pub status: u8,
    pub placement: Option<u16>,
    pub proofs: Vec<(u16, Vec<usize>)>,
    pub truths: Vec<u16>,
    pub falses: Vec<u16>,
}

pub(crate) fn analyze(
    board: &Board,
    nodes: &[&[u16]],
    edges: &[u8],
    closed: bool,
    batch: bool,
) -> Analysis {
    let n = nodes.len();
    if n < 2 {
        return Analysis::default();
    }
    let mut seen = HashSet::new();
    let mut present = HashSet::new();
    if edges.len() != n - usize::from(!closed)
        || nodes.iter().any(|&node| {
            !seen.insert(node)
                || node.is_empty()
                || !node.windows(2).all(|x| x[0] < x[1])
                || node.iter().any(|&a| {
                    present.insert(a);
                    a / 10 >= 81
                        || !(1..=9).contains(&(a % 10))
                        || board.masks[usize::from(a / 10)] & (1 << (a % 10 - 1)) == 0
                })
        })
    {
        return Analysis {
            status: 1,
            ..Default::default()
        };
    }
    let mut sources = Sources::new(board);
    let mut assumed = false;
    let mut base = vec![Vec::new(); 2 * (n + 1)];
    for (i, &edge) in edges.iter().enumerate() {
        let next = (i + 1) % n;
        let (a, b) = (nodes[i], nodes[next]);
        let valid = if edge == 1 {
            sources.ordinary(a, b) || sources.als(board, a, b)
        } else {
            weak(a, b)
        };
        assumed |= !valid;
        connect(&mut base, i, next, edge == 1);
    }
    let mut result = Analysis {
        status: if assumed { 1 } else { 2 },
        ..Default::default()
    };
    for (c, &mask) in board.masks.iter().enumerate() {
        for d in digits(mask) {
            let target = c as u16 * 10 + u16::from(d);
            let idx = nodes.iter().position(|&node| node == [target]).unwrap_or(n);
            let mut graph = base.clone();
            for (i, &node) in nodes.iter().enumerate() {
                if weak(&[target], node) {
                    connect(&mut graph, idx, i, false);
                }
                if node.len() > 1 && node.binary_search(&target).is_ok() {
                    graph[idx * 2 + 1].push(i * 2 + 1);
                    graph[i * 2].push(idx * 2);
                }
            }
            if present.contains(&target) {
                if let Some(path) = proof(&graph, idx * 2) {
                    if result.placement.is_none() {
                        result.placement = Some(target);
                        result.proofs = vec![(target, path)];
                        result.status = if assumed { 4 } else { 3 };
                        if !batch {
                            return result;
                        }
                    }
                    result.truths.push(target);
                }
            }
            if let Some(path) = proof(&graph, idx * 2 + 1) {
                if batch {
                    result.falses.push(target);
                }
                if result.placement.is_none() {
                    result.proofs.push((target, path));
                }
            }
        }
    }
    if !result.proofs.is_empty() {
        result.status = if assumed { 4 } else { 3 };
    }
    result
}

/// Evaluates exactly the supplied authored relations against the current ordinary candidates.
pub fn evaluate(
    values: &[u8; 81],
    masks: &[u16; 81],
    nodes: &[&[u16]],
    edges: &[u8],
    closed: bool,
) -> Result<Analysis, crate::InvalidInput> {
    evaluate_selected(values, masks, nodes, edges, closed, false)
}

/// The reading presents the first Java step. Transcription needs every conclusion.
pub fn evaluate_selected(
    values: &[u8; 81],
    masks: &[u16; 81],
    nodes: &[&[u16]],
    edges: &[u8],
    closed: bool,
    batch: bool,
) -> Result<Analysis, crate::InvalidInput> {
    if edges.iter().any(|&e| e > 1) {
        return Err(crate::InvalidInput);
    }
    let board = crate::hints::checked_board(values, masks)?;
    Ok(analyze(&board, nodes, edges, closed, batch))
}
