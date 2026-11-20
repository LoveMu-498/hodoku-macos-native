// SPDX-License-Identifier: GPL-3.0-or-later
// FindAllSteps/SolutionStep.compareTo. WingSolver.getAllWings retains discovery order.
use super::{digit_sets, patterns, Options, Step};
use std::cmp::Ordering;
use std::ops::ControlFlow;

fn equal_members<T: Eq>(a: &[T], b: &[T]) -> bool {
    a.len() == b.len() && a.iter().all(|v| b.contains(v))
}
fn deletion_weight(s: &Step) -> usize {
    s.deletes
        .iter()
        .enumerate()
        .map(|(i, &(c, d))| (1 + 80 * i) * c as usize + d as usize)
        .sum()
}
fn sum(items: &[u8]) -> usize {
    items.iter().copied().map(usize::from).sum()
}
pub(super) fn compare(a: &Step, b: &Step) -> Ordering {
    let by_count = b.deletes.len().cmp(&a.deletes.len());
    if by_count != Ordering::Equal {
        return by_count;
    }
    let chain_len = |s: &Step| s.chains.iter().map(Vec::len).sum::<usize>();
    let by_chain = chain_len(a).cmp(&chain_len(b));
    if by_chain != Ordering::Equal {
        return by_chain;
    }
    if a.kind != b.kind || !equal_members(&a.deletes, &b.deletes) {
        return deletion_weight(a).cmp(&deletion_weight(b));
    }
    if !equal_members(&a.values, &b.values) {
        return sum(&a.values).cmp(&sum(&b.values));
    }
    if !equal_members(&a.indices, &b.indices) {
        return a
            .indices
            .len()
            .cmp(&b.indices.len())
            .then_with(|| sum(&b.indices).cmp(&sum(&a.indices)));
    }
    Ordering::Equal
}
pub fn catalogue(
    _values: &[u8; 81],
    masks: &[u16; 81],
    kind: &str,
    cancelled: &dyn Fn() -> bool,
) -> Option<Vec<Step>> {
    catalogue_with_options(_values, masks, kind, &Options::default(), cancelled)
}
pub fn catalogue_with_options(
    values: &[u8; 81],
    masks: &[u16; 81],
    kind: &str,
    options: &Options,
    cancelled: &dyn Fn() -> bool,
) -> Option<Vec<Step>> {
    let sets = digit_sets(masks);
    if let Some(spec) = super::fish::spec(kind) {
        return Some(super::fish::catalogue(
            values, &sets, spec, kind, options, cancelled,
        ));
    }
    let chain = match kind {
        "REMOTE_PAIR" => Some("REMOTE_PAIR"),
        "TURBOT_FISH" => Some("TURBOT_FISH"),
        "X_CHAIN" => Some("X_CHAIN"),
        "XY_CHAIN" => Some("XY_CHAIN"),
        _ => None,
    };
    if let Some(name) = chain {
        let steps = super::chains::search(
            masks,
            &sets,
            name,
            cancelled,
            true,
            options.chain_limit(),
            options.fine_scope.as_ref(),
        );
        return Some(if cancelled() { vec![] } else { steps });
    }
    if kind == "BUG_PLUS_1" {
        return Some(super::patterns::bug(masks, &sets).into_iter().collect());
    }
    if !matches!(
        kind,
        "XY_WING"
            | "XYZ_WING"
            | "W_WING"
            | "SKYSCRAPER"
            | "TWO_STRING_KITE"
            | "DUAL_TWO_STRING_KITE"
            | "DUAL_EMPTY_RECTANGLE"
            | "EMPTY_RECTANGLE"
            | "SIMPLE_COLORS"
            | "MULTI_COLORS"
            | "SIMPLE_COLORS_WRAP"
            | "SIMPLE_COLORS_TRAP"
            | "MULTI_COLORS_1"
            | "MULTI_COLORS_2"
    ) {
        return None;
    }
    let mut steps = pattern_list(masks, &sets, kind, options, cancelled);
    if !matches!(kind, "SIMPLE_COLORS" | "MULTI_COLORS") {
        steps.retain(|s| s.kind == kind);
    }
    Some(steps)
}
pub(super) fn pattern_list(
    masks: &[u16; 81],
    sets: &[u128; 10],
    kind: &str,
    options: &Options,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    let mut steps = vec![];
    if cancelled() {
        return steps;
    }
    let _ = patterns(masks, sets, kind, options, &mut |s| {
        if cancelled() {
            return ControlFlow::Break(s);
        }
        steps.push(s);
        ControlFlow::Continue(())
    });
    if cancelled() {
        steps.clear();
    } else {
        if options.duals
            && matches!(
                kind,
                "TWO_STRING_KITE"
                    | "DUAL_TWO_STRING_KITE"
                    | "EMPTY_RECTANGLE"
                    | "DUAL_EMPTY_RECTANGLE"
            )
        {
            let count = steps.len();
            for i in 0..count {
                for j in i + 1..count {
                    let (a, b) = (&steps[i], &steps[j]);
                    let kite = a.kind == "TWO_STRING_KITE";
                    let same = if kite {
                        equal_members(&a.indices[2..], &b.indices[2..])
                    } else {
                        a.house == b.house && a.fins == b.fins
                    };
                    if same && a.deletes[0] != b.deletes[0] {
                        let mut dual = a.clone();
                        dual.kind = if kite {
                            "DUAL_TWO_STRING_KITE"
                        } else {
                            "DUAL_EMPTY_RECTANGLE"
                        };
                        dual.indices.extend(&b.indices);
                        dual.deletes.push(b.deletes[0]);
                        steps.push(dual);
                    }
                }
            }
        }
        if !matches!(kind, "XY_WING" | "XYZ_WING" | "W_WING") {
            steps.sort_by(compare);
        }
    }
    steps
}
