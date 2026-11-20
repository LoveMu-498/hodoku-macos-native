// SPDX-License-Identifier: GPL-3.0-or-later
// Rectangle traversal and evidence adapted from HoDoKu UniquenessSolver (C) 2008–12 Bernhard Hobiger.
use super::Step;
use crate::board::{digits, houses};
use crate::hints::UNITS;
use std::collections::HashSet;

const KINDS: [&str; 9] = [
    "UNIQUENESS_1",
    "UNIQUENESS_2",
    "UNIQUENESS_3",
    "UNIQUENESS_4",
    "UNIQUENESS_5",
    "UNIQUENESS_6",
    "HIDDEN_RECTANGLE",
    "AVOIDABLE_RECTANGLE_1",
    "AVOIDABLE_RECTANGLE_2",
];
pub fn supports(name: &str) -> bool {
    KINDS.contains(&name)
}

fn bit(d: u8) -> u16 {
    1 << (d - 1)
}
fn sees(a: usize, b: usize) -> bool {
    a != b && houses(a).into_iter().zip(houses(b)).any(|(x, y)| x == y)
}
fn aligned(a: usize, b: usize) -> bool {
    a / 9 == b / 9 || a % 9 == b % 9
}

struct Rectangle<'a> {
    corners: [usize; 4],
    pair: [u8; 2],
    masks: &'a [u16; 81],
}

impl Rectangle<'_> {
    fn step(&self, kind: &'static str) -> Step {
        Step {
            kind,
            indices: self.corners.iter().map(|&c| c as u8).collect(),
            values: self.pair.to_vec(),
            ..Step::default()
        }
    }

    fn exclude(&self, step: &mut Step, cell: usize, mask: u16) {
        step.deletes
            .extend(digits(self.masks[cell] & mask).map(|d| (cell as u8, d)));
    }

    fn ur(&self, kind: &'static str, out: &mut Results) -> Option<Step> {
        let [a, b] = self.pair;
        let mask = bit(a) | bit(b);
        let mut plain = Vec::new();
        let mut extra = Vec::new();
        for &c in &self.corners {
            if self.masks[c] & !mask == 0 {
                plain.push(c)
            } else {
                extra.push(c)
            }
        }
        plain.sort_unstable();
        extra.sort_unstable();
        let mut s = self.step(kind);
        match (kind, extra.as_slice()) {
            ("UNIQUENESS_1", [only]) => self.exclude(&mut s, *only, mask),
            ("UNIQUENESS_2" | "UNIQUENESS_5", [i, j, ..])
                if extra.len() == 2 || extra.len() == 3 =>
            {
                let extras = extra.iter().fold(0, |m, &c| m | self.masks[c] & !mask);
                let two = extra.len() == 2 && aligned(*i, *j);
                if extras.count_ones() != 1 || (kind == "UNIQUENESS_2") != two {
                    return None;
                }
                for c in 0..81 {
                    if extra.iter().all(|&e| sees(c, e)) {
                        self.exclude(&mut s, c, extras)
                    }
                }
            }
            ("UNIQUENESS_3", [i, j]) => {
                let extras = (self.masks[*i] | self.masks[*j]) & !mask;
                for h in houses(*i) {
                    if !houses(*j).contains(&h) {
                        continue;
                    }
                    let cells: Vec<_> = UNITS[h]
                        .iter()
                        .copied()
                        .filter(|c| {
                            !self.corners.contains(c)
                                && self.masks[*c] != 0
                                && self.masks[*c] & mask == 0
                        })
                        .collect();
                    if let Some(s) = self.ur3(h, &cells, 0, &mut vec![*i, *j], extras, out) {
                        return Some(s);
                    }
                }
            }
            ("UNIQUENESS_4", [i, j]) if aligned(*i, *j) => {
                let common = (0..81)
                    .filter(|&c| sees(*i, c) && sees(*j, c))
                    .fold(0, |m, c| m | self.masks[c]);
                let d = if common & bit(a) == 0 {
                    b
                } else if common & bit(b) == 0 {
                    a
                } else {
                    return None;
                };
                for c in [*i, *j] {
                    self.exclude(&mut s, c, bit(d));
                }
            }
            ("UNIQUENESS_6", [i, j]) if !aligned(*i, *j) => {
                let others = (0..81)
                    .filter(|c| !self.corners.contains(c) && (aligned(*i, *c) || aligned(*j, *c)))
                    .fold(0, |m, c| m | self.masks[c]);
                let d = if others & bit(a) == 0 {
                    a
                } else if others & bit(b) == 0 {
                    b
                } else {
                    return None;
                };
                for c in [*i, *j] {
                    self.exclude(&mut s, c, bit(d));
                }
            }
            ("HIDDEN_RECTANGLE", _)
                if plain.len() == 1 || plain.len() == 2 && !aligned(plain[0], plain[1]) =>
            {
                for &c in &plain {
                    let i = extra[0];
                    let j = extra[1];
                    let r = if i / 9 == c / 9 { j / 9 } else { i / 9 };
                    let col = if i % 9 == c % 9 { j % 9 } else { i % 9 };
                    let rest = UNITS[r]
                        .iter()
                        .chain(&UNITS[9 + col])
                        .filter(|x| !self.corners.contains(x))
                        .fold(0, |m, &x| m | self.masks[x]);
                    for (first, second) in [(a, b), (b, a)] {
                        if rest & bit(first) == 0 {
                            self.exclude(&mut s, r * 9 + col, bit(second));
                        }
                        if !s.deletes.is_empty() {
                            if out.first_only {
                                return Some(s);
                            }
                            out.steps.push(s);
                            s = self.step(kind);
                        }
                    }
                }
            }
            _ => {}
        }
        (!s.deletes.is_empty()).then_some(s)
    }

    fn ur3(
        &self,
        h: usize,
        eligible: &[usize],
        start: usize,
        selected: &mut Vec<usize>,
        extras: u16,
        out: &mut Results,
    ) -> Option<Step> {
        for ix in start..eligible.len() {
            let c = eligible[ix];
            selected.push(c);
            let masks = extras | self.masks[c];
            let aligned = selected.iter().all(|&c| c / 9 == selected[0] / 9)
                || selected.iter().all(|&c| c % 9 == selected[0] % 9);
            if masks.count_ones() as usize == selected.len() - 1 && !(h >= 18 && aligned) {
                let mut s = self.step("UNIQUENESS_3");
                for &i in &UNITS[h] {
                    if !selected.contains(&i) {
                        self.exclude(&mut s, i, masks);
                    }
                }
                if !s.deletes.is_empty() {
                    for d in digits(masks) {
                        for (i, &m) in self.masks.iter().enumerate() {
                            if selected.contains(&i) && m & bit(d) != 0 {
                                s.fins.push((i as u8, d));
                            }
                        }
                    }
                    let block = houses(c)[2];
                    if h < 18 && selected.iter().all(|&i| houses(i)[2] == block) {
                        for &i in &UNITS[block] {
                            if !selected.contains(&i) {
                                self.exclude(&mut s, i, masks);
                            }
                        }
                    }
                    if out.first_only {
                        return Some(s);
                    }
                    out.steps.push(s);
                }
            }
            if let Some(s) = self.ur3(h, eligible, ix + 1, selected, masks, out) {
                return Some(s);
            }
            selected.pop();
        }
        None
    }

    fn ar(&self, kind: &'static str, values: &[u8; 81]) -> Option<Step> {
        let [_, _, c, d] = self.corners;
        let [a, b] = self.pair;
        let mut s = self.step(kind);
        if values[c] != 0 || values[d] != 0 {
            if kind != "AVOIDABLE_RECTANGLE_1" {
                return None;
            }
            if values[c] != 0 {
                self.exclude(&mut s, d, bit(a));
            } else {
                self.exclude(&mut s, c, bit(b));
            }
        } else {
            if kind != "AVOIDABLE_RECTANGLE_2" {
                return None;
            }
            let other = self.masks[c] & !bit(b);
            if other.count_ones() != 1 || self.masks[d] & other == 0 {
                return None;
            }
            for i in 0..81 {
                if sees(c, i) && sees(d, i) {
                    self.exclude(&mut s, i, other)
                }
            }
            let digit = other.trailing_zeros() as u8 + 1;
            s.endo_fins = vec![(c as u8, digit), (d as u8, digit)];
        }
        (!s.deletes.is_empty()).then_some(s)
    }
}

struct Results {
    first_only: bool,
    steps: Vec<Step>,
}
struct Position<'a> {
    values: &'a [u8; 81],
    masks: &'a [u16; 81],
    fixed: &'a [bool; 81],
    allow_missing: bool,
}

/// The caller checks unique current values for UR, plus unique givens for AR.
pub fn first(
    values: &[u8; 81],
    masks: &[u16; 81],
    fixed: &[bool; 81],
    name: &str,
    allow_missing: bool,
) -> Option<Step> {
    let kind = *KINDS.iter().find(|&&v| v == name)?;
    let position = Position {
        values,
        masks,
        fixed,
        allow_missing,
    };
    position.scan(
        kind,
        kind.starts_with("AVOIDABLE"),
        &mut HashSet::new(),
        &mut Results {
            first_only: true,
            steps: vec![],
        },
    )
}
pub fn catalogue(
    values: &[u8; 81],
    masks: &[u16; 81],
    fixed: &[bool; 81],
    name: &str,
    allow_missing: bool,
) -> Vec<Step> {
    let Some(&kind) = KINDS.iter().find(|&&k| k == name) else {
        return vec![];
    };
    let position = Position {
        values,
        masks,
        fixed,
        allow_missing,
    };
    let mut out = Results {
        first_only: false,
        steps: vec![],
    };
    let mut seen = HashSet::new();
    let ar = kind.starts_with("AVOIDABLE");
    if ar {
        position.scan("", false, &mut seen, &mut out);
    }
    position.scan(kind, ar, &mut seen, &mut out);
    out.steps
}
impl Position<'_> {
    fn scan(
        &self,
        kind: &'static str,
        ar: bool,
        visited: &mut HashSet<usize>,
        out: &mut Results,
    ) -> Option<Step> {
        let Self {
            values,
            masks,
            fixed,
            allow_missing,
        } = *self;
        let mut allowed = [0u16; 81];
        if allow_missing && !ar {
            for i in 0..81 {
                if values[i] == 0 {
                    allowed[i] = (0..81)
                        .filter(|&j| values[j] != 0 && sees(i, j))
                        .fold(511, |m, j| m & !bit(values[j]));
                }
            }
        }

        for a in 0..81 {
            if if ar {
                values[a] == 0 || fixed[a]
            } else {
                masks[a].count_ones() != 2
            } {
                continue;
            }
            let group = houses(a)[2];
            for _ in 0..if ar && !out.first_only { 2 } else { 1 } {
                for &b in &UNITS[group] {
                    if b == a || !aligned(a, b) {
                        continue;
                    }
                    let (first, second) = if ar {
                        if values[b] == 0 || fixed[b] {
                            continue;
                        }
                        (values[a], values[b])
                    } else {
                        if masks[a] & (if allow_missing { allowed[b] } else { masks[b] })
                            != masks[a]
                        {
                            continue;
                        }
                        let lo = masks[a].trailing_zeros() as u8 + 1;
                        (lo, (masks[a] & !bit(lo)).trailing_zeros() as u8 + 1)
                    };
                    let axis = usize::from(a / 9 == b / 9);
                    let ha = houses(a)[axis];
                    let hb = houses(b)[axis];
                    for (&c, &d) in UNITS[ha].iter().zip(&UNITS[hb]) {
                        if houses(c)[2] == group {
                            continue;
                        }
                        let valid = if ar {
                            let lc = masks[c].count_ones() == 2 && masks[c] & bit(second) != 0;
                            let ld = masks[d].count_ones() == 2 && masks[d] & bit(first) != 0;
                            (values[c] == second && !fixed[c] && ld)
                                || (values[d] == first && !fixed[d] && lc)
                                || (lc && ld)
                        } else if allow_missing {
                            // The frozen search tests digit one on the first opposite corner,
                            // and both digits on the second (UniquenessSolver.java:426).
                            allowed[c] & bit(first) != 0 && allowed[d] & masks[a] == masks[a]
                        } else {
                            masks[c] & masks[a] == masks[a] && masks[d] & masks[a] == masks[a]
                        };
                        if !valid {
                            continue;
                        }
                        let mut sorted = [a, b, c, d];
                        sorted.sort_unstable();
                        // Java checkRect sorts, then packs in radix 10 even for two-digit indices.
                        let key = sorted.into_iter().fold(0, |key, c| key * 10 + c);
                        if visited.contains(&key) {
                            continue;
                        }
                        if visited.len() < 400 {
                            visited.insert(key);
                        }
                        let rectangle = Rectangle {
                            corners: [a, b, c, d],
                            pair: [first, second],
                            masks,
                        };
                        let found = if ar {
                            rectangle.ar(kind, values)
                        } else {
                            rectangle.ur(kind, out)
                        };
                        if let Some(s) = found {
                            if out.first_only {
                                return Some(s);
                            }
                            out.steps.push(s);
                        }
                    }
                }
            }
        }
        None
    }
}
