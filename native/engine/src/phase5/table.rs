// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from TablingSolver (C) Bernhard Hobiger.
mod forcing;
mod graph;
pub mod kraken;
mod net;
use self::graph::{cells, Graph};
use super::Step;
use crate::board::digits;

pub fn supports(kind: &str) -> bool {
    matches!(
        kind,
        "FORCING_NET"
            | "FORCING_NET_CONTRADICTION"
            | "FORCING_NET_VERITY"
            | "FORCING_CHAIN"
            | "FORCING_CHAIN_CONTRADICTION"
            | "FORCING_CHAIN_VERITY"
            | "NICE_LOOP"
            | "CONTINUOUS_NICE_LOOP"
            | "DISCONTINUOUS_NICE_LOOP"
            | "AIC"
            | "GROUPED_NICE_LOOP"
            | "GROUPED_CONTINUOUS_NICE_LOOP"
            | "GROUPED_DISCONTINUOUS_NICE_LOOP"
            | "GROUPED_AIC"
    )
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Options {
    pub allow_als: bool,
    pub max_entries: usize,
    pub look_ahead: usize,
    pub only_one_chain: bool,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            allow_als: false,
            max_entries: 1000,
            look_ahead: 4,
            only_one_chain: true,
        }
    }
}

#[derive(Clone, Copy)]
enum Query<'a> {
    First,
    Catalogue,
    Matching(&'a dyn Fn(&Step) -> bool),
}
impl<'a> Query<'a> {
    fn predicate(self) -> Option<&'a dyn Fn(&Step) -> bool> {
        if let Self::Matching(p) = self {
            Some(p)
        } else {
            None
        }
    }
}
pub fn first(
    values: &[u8; 81],
    masks: &[u16; 81],
    kind: &str,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    first_with_options(values, masks, kind, &Options::default(), cancelled)
}
pub fn first_with_options(
    values: &[u8; 81],
    masks: &[u16; 81],
    kind: &str,
    options: &Options,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    search(values, masks, kind, options, cancelled, Query::First)
        .into_iter()
        .next()
}
pub fn catalogue(
    values: &[u8; 81],
    masks: &[u16; 81],
    kind: &str,
    options: &Options,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    search(values, masks, kind, options, cancelled, Query::Catalogue)
}
pub fn matching(
    values: &[u8; 81],
    masks: &[u16; 81],
    kind: &str,
    options: &Options,
    predicate: &dyn Fn(&Step) -> bool,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    search(
        values,
        masks,
        kind,
        options,
        cancelled,
        Query::Matching(predicate),
    )
}
fn named(kind: &str, actual: &str) -> bool {
    kind == actual
        || matches!(
            kind,
            "NICE_LOOP" | "GROUPED_NICE_LOOP" | "FORCING_CHAIN" | "FORCING_NET"
        )
}
fn search(
    values: &[u8; 81],
    masks: &[u16; 81],
    kind: &str,
    options: &Options,
    cancelled: &dyn Fn() -> bool,
    query: Query<'_>,
) -> Vec<Step> {
    let all = !matches!(query, Query::First);
    let predicate = query.predicate();
    if !supports(kind) || cancelled() || options.max_entries == 0 {
        return vec![];
    }
    let grouped = kind.starts_with("GROUPED");
    let mut graph = Graph::new(masks, grouped || kind.starts_with("FORCING"));
    if options.allow_als && (grouped || kind.starts_with("FORCING")) {
        graph.include_als(masks, cancelled);
    }
    if kind.starts_with("FORCING") {
        return forcing::search(values, masks, &graph, kind, options, query, cancelled);
    }
    let mut list = vec![];
    let mut raw_matches = vec![];
    let mut minimum = std::collections::HashMap::new();
    let mut best = None;
    for (on, aic) in [(true, false), (false, false), (false, true)] {
        for id in 0..graph.ordinary {
            if cancelled() {
                return vec![];
            }
            let start = id * 2 + usize::from(on);
            let origin = graph.node(start);
            let reach = graph.reachable(start, options.max_entries);
            for &end in &reach.queue[1..] {
                if end / 2 >= graph.ordinary {
                    continue;
                }
                let finish = graph.node(end);
                let same = finish.cell == origin.cell;
                if aic {
                    if same || end & 1 == 0 {
                        continue;
                    }
                    if finish.digit == origin.digit {
                        if (origin.buddies
                            & finish.buddies
                            & graph.candidates[origin.digit as usize])
                            .count_ones()
                            < 2
                        {
                            continue;
                        }
                    } else if origin.buddies & finish.cells == 0
                        || masks[origin.cell] & (1 << (finish.digit - 1)) == 0
                        || masks[finish.cell] & (1 << (origin.digit - 1)) == 0
                    {
                        continue;
                    }
                } else if !same {
                    continue;
                }
                let path = reach.path(end);
                if path.len() < 3 || !valid_path(&graph, &path, aic) {
                    continue;
                }
                let mut step = if aic {
                    let deletes = if finish.digit == origin.digit {
                        cells(
                            origin.buddies
                                & finish.buddies
                                & graph.candidates[origin.digit as usize],
                        )
                        .map(|c| (c as u8, origin.digit))
                        .collect()
                    } else {
                        vec![
                            (origin.cell as u8, finish.digit),
                            (finish.cell as u8, origin.digit),
                        ]
                    };
                    Step {
                        kind: "AIC",
                        deletes,
                        ..Step::default()
                    }
                } else {
                    let Some(s) = nice(&graph, masks, &path) else {
                        continue;
                    };
                    s
                };
                if path.iter().any(|n| n / 2 >= graph.ordinary) {
                    step.kind = match step.kind {
                        "AIC" => "GROUPED_AIC",
                        "CONTINUOUS_NICE_LOOP" => "GROUPED_CONTINUOUS_NICE_LOOP",
                        _ => "GROUPED_DISCONTINUOUS_NICE_LOOP",
                    }
                }
                step.chains
                    .push(path.iter().map(|n| graph.code(*n)).collect());
                let raw_len = (path.len() * 2
                    + 5 * path
                        .iter()
                        .filter(|&&n| graph.node(n).als.is_some())
                        .count())
                    / 2;
                graph.adjust(&mut step);
                if all && grouped && !step.kind.starts_with("GROUPED") {
                    continue;
                }
                if let Some(matches) = predicate {
                    if named(kind, step.kind) && matches(&step) {
                        raw_matches.push(step)
                    }
                    continue;
                }
                step.deletes.sort_by_key(|&(c, d)| (d, c));
                step.deletes.dedup();
                let key = (step.kind, step.deletes.clone());
                let prior = minimum.get(&key).copied();
                if prior.is_some_and(|n| n <= raw_len) {
                    continue;
                }
                // Nice loops cache getLength(null) before cloning. AIC computes it lazily
                // unless Java compared it to a previous proof of the same elimination.
                let cached = if !aic || prior.is_some() {
                    raw_len
                } else {
                    graph::length(&step)
                };
                minimum.insert(key, cached);
                let ordering = rank(&step, cached);
                if all {
                    list.push((ordering, step));
                } else if best.as_ref().is_none_or(|(k, _)| ordering < *k) {
                    best = Some((ordering, step));
                }
            }
        }
    }
    if predicate.is_some() {
        return raw_matches;
    }
    if !all {
        return best.into_iter().map(|(_, s)| s).collect();
    }
    list.sort_by_key(|(k, _)| *k);
    list.into_iter()
        .map(|(_, s)| s)
        .filter(|s| named(kind, s.kind))
        .collect()
}

fn rank(s: &Step, length: usize) -> (std::cmp::Reverse<usize>, usize, usize) {
    let weight = s
        .deletes
        .iter()
        .enumerate()
        .map(|(i, &(c, d))| usize::from(c) * (1 + 80 * i) + usize::from(d))
        .sum();
    (std::cmp::Reverse(s.deletes.len()), length, weight)
}

fn valid_path(g: &Graph, path: &[usize], aic: bool) -> bool {
    let first = g.node(path[0]);
    if !aic
        && (g.node(path[1]).cell == first.cell || g.node(path[path.len() - 2]).cell == first.cell)
    {
        return false;
    }
    let mut visited = 0;
    for i in 1..path.len() {
        let cell = g.node(path[i]).cell;
        if visited & (1 << cell) != 0 {
            return false;
        }
        let prev = g.node(path[i - 1]);
        if prev.cell != first.cell || aic {
            visited |= prev.cells;
        }
    }
    true
}

fn nice(g: &Graph, masks: &[u16; 81], p: &[usize]) -> Option<Step> {
    let start = g.node(p[0]);
    let last = g.node(*p.last()?);
    let first_on = p[1] % 2 == 1;
    let last_on = p.last()? % 2 == 1;
    let mut step = Step {
        kind: "DISCONTINUOUS_NICE_LOOP",
        ..Step::default()
    };
    match (first_on, last_on, start.digit == last.digit) {
        (false, false, true) => step.deletes.push((start.cell as u8, start.digit)),
        (true, true, true) => step.deletes.extend(
            digits(masks[start.cell])
                .filter(|&d| d != start.digit)
                .map(|d| (start.cell as u8, d)),
        ),
        (a, b, false) if a != b => step
            .deletes
            .push((start.cell as u8, if a { last.digit } else { start.digit })),
        (false, false, false) if masks[start.cell].count_ones() != 2 => return None,
        _ => {
            step.kind = "CONTINUOUS_NICE_LOOP";
            let occupied = p
                .iter()
                .take(p.len() - 1)
                .fold(0, |acc, &n| acc | g.node(n).cells);
            for i in 0..p.len() {
                let n = g.node(p[i]);
                let strongs = if i == 0 && first_on && last_on {
                    Some((start.digit, last.digit))
                } else if i > 0
                    && i + 2 < p.len()
                    && p[i] % 2 == 1
                    && p[i + 1] & 1 == 0
                    && p[i + 2] % 2 == 1
                    && g.node(p[i - 1]).cell != n.cell
                    && n.cell == g.node(p[i + 1]).cell
                    && n.cell != g.node(p[i + 2]).cell
                {
                    Some((n.digit, g.node(p[i + 2]).digit))
                } else {
                    None
                };
                if let Some((a, b)) = strongs {
                    step.deletes.extend(
                        digits(masks[n.cell])
                            .filter(|&d| d != a && d != b)
                            .map(|d| (n.cell as u8, d)),
                    );
                }
                if i > 0 && p[i] & 1 == 0 && n.cell != g.node(p[i - 1]).cell {
                    step.deletes.extend(
                        cells(
                            g.buddies_for(p[i], n.digit)
                                & g.buddies_for(p[i - 1], n.digit)
                                & !occupied
                                & g.candidates[n.digit as usize],
                        )
                        .map(|c| (c as u8, n.digit)),
                    );
                    if let Some(id) = n.als {
                        let als = &g.alses[id];
                        let next = g.node(p[i + 1]);
                        let forced = p[i + 1] % 2 == 1;
                        let exits = if forced {
                            masks[next.cell] & !(1 << (next.digit - 1))
                        } else {
                            1 << (next.digit - 1)
                        };
                        for d in digits(als.mask) {
                            if d == n.digit {
                                continue;
                            }
                            let targets = if exits >> (d - 1) & 1 == 0 {
                                als.outside[d as usize]
                            } else if forced {
                                als.outside[d as usize] & next.buddies
                            } else {
                                0
                            };
                            step.deletes.extend(cells(targets).map(|c| (c as u8, d)));
                        }
                    }
                }
            }
        }
    }
    (!step.deletes.is_empty()).then_some(step)
}
