// SPDX-License-Identifier: GPL-3.0-or-later
// TemplateSolver and SudokuStepFinder.initCandTemplates, Bernhard Hobiger.
use super::Step;
use std::sync::OnceLock;

pub(super) fn supports(name: &str) -> bool {
    matches!(
        name,
        "BRUTE_FORCE" | "TEMPLATE_SET" | "TEMPLATE_DEL" | "GIVE_UP" | "INCOMPLETE"
    )
}

/// The 46,656 ways a digit can occupy every row, column and box once.
pub(super) fn templates() -> &'static [u128] {
    static ALL: OnceLock<Vec<u128>> = OnceLock::new();
    ALL.get_or_init(|| {
        fn row(r: usize, cols: u16, boxes: u16, cells: u128, out: &mut Vec<u128>) {
            if r == 9 {
                out.push(cells);
                return;
            }
            for c in 0..9 {
                let b = r / 3 * 3 + c / 3;
                if cols & (1 << c) == 0 && boxes & (1 << b) == 0 {
                    row(
                        r + 1,
                        cols | (1 << c),
                        boxes | (1 << b),
                        cells | (1 << (r * 9 + c)),
                        out,
                    );
                }
            }
        }
        let mut out = Vec::with_capacity(46656);
        row(0, 0, 0, 0, &mut out);
        out
    })
}

pub(super) fn first(
    values: &[u8; 81],
    masks: &[u16; 81],
    name: &str,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    if name == "GIVE_UP" {
        return Some(Step {
            kind: "GIVE_UP",
            ..Step::default()
        });
    }
    if name == "INCOMPLETE" {
        return None;
    }
    if name == "BRUTE_FORCE" {
        let found = crate::count_solutions(values, Some(masks), 1, 1_000_000, cancelled)
            .ok()?
            .solution?;
        let empty = (0..81).filter(|&i| values[i] == 0).collect::<Vec<_>>();
        let cell = *empty.get(empty.len() / 2)?;
        return Some(Step {
            kind: "BRUTE_FORCE",
            indices: vec![cell as u8],
            values: vec![found[cell]],
            ..Step::default()
        });
    }
    templates_for(values, masks, name, cancelled)
        .into_iter()
        .next()
}

pub(super) fn templates_for(
    values: &[u8; 81],
    masks: &[u16; 81],
    name: &str,
    cancelled: &dyn Fn() -> bool,
) -> Vec<Step> {
    let mut steps = Vec::new();
    let mut placed = [0u128; 9];
    let mut possible = [0u128; 9];
    for cell in 0..81 {
        if values[cell] != 0 {
            placed[usize::from(values[cell] - 1)] |= 1 << cell;
        }
        for d in crate::board::digits(masks[cell]) {
            possible[usize::from(d - 1)] |= 1 << cell;
        }
    }
    const GRID: u128 = (1 << 81) - 1;
    let mut lists: [Vec<u128>; 9] = std::array::from_fn(|_| Vec::new());
    let mut common = [GRID; 9];
    let mut union = [0; 9];
    for d in 0..9 {
        if cancelled() {
            return Vec::new();
        }
        let allowed = possible[d] | placed[d];
        for &t in templates() {
            if t & placed[d] == placed[d] && t & !allowed == 0 {
                lists[d].push(t);
                common[d] &= t;
            }
        }
    }
    loop {
        let mut changed = false;
        for d in 0..9 {
            if cancelled() {
                return Vec::new();
            }
            let occupied = common
                .iter()
                .enumerate()
                .filter(|(i, _)| *i != d)
                .fold(0, |n, (_, m)| n | m);
            let old = lists[d].len();
            common[d] = GRID;
            union[d] = 0;
            lists[d].retain(|&t| {
                if t & occupied != 0 {
                    return false;
                }
                common[d] &= t;
                union[d] |= t;
                true
            });
            changed |= old != lists[d].len();
        }
        if !changed {
            break;
        }
    }
    for d in 0..9 {
        let set = name == "TEMPLATE_SET";
        let cells = if set {
            common[d] & !placed[d]
        } else {
            possible[d] & !union[d]
        };
        if cells == 0 {
            continue;
        }
        let digit = (d + 1) as u8;
        let ids = (0..81u8).filter(|&i| cells & (1 << i) != 0);
        let mut step = Step {
            kind: if set { "TEMPLATE_SET" } else { "TEMPLATE_DEL" },
            values: vec![digit],
            ..Step::default()
        };
        if set {
            step.indices.extend(ids);
        } else {
            step.deletes.extend(ids.map(|i| (i, digit)));
        }
        steps.push(step);
    }
    steps
}
