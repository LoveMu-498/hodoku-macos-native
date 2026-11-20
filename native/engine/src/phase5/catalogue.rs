// SPDX-License-Identifier: GPL-3.0-or-later
use super::{
    advanced, als, basic::BasicState, basic_kind, consistent, last_resort, scoring::Policy, Ending,
    Path,
};
use crate::{board::Board, InvalidInput};

pub fn collect(
    values: &[u8; 81],
    masks: &[u16; 81],
    fixed: &[bool; 81],
    policy: &Policy,
    cancelled: &dyn Fn() -> bool,
) -> Result<Path, InvalidInput> {
    let [rule] = policy.rules.as_slice() else {
        return Err(InvalidInput);
    };
    Board::from_snapshot(values, Some(masks))?;
    if !consistent(values, masks) {
        return Err(InvalidInput);
    }
    let kind = rule.name.as_str();
    let scope = policy.advanced.fine_scope.as_ref();
    let steps = if basic_kind(kind) {
        Some(BasicState::new(values, masks).catalogue(kind))
    } else if super::uniqueness::supports(kind) || kind == "BUG_PLUS_1" {
        let unique = crate::count_solutions(values, Some(masks), 1, 1_000_000, cancelled)?
            .solution
            .is_some();
        let givens = std::array::from_fn(|i| if fixed[i] { values[i] } else { 0 });
        if !unique
            || (kind.starts_with("AVOIDABLE")
                && crate::count_solutions(&givens, None, 1, 1_000_000, cancelled)?
                    .solution
                    .is_none())
        {
            Some(Vec::new())
        } else if kind == "BUG_PLUS_1" {
            advanced::catalogue_with_options(values, masks, kind, &policy.advanced, cancelled)
        } else {
            Some(super::uniqueness::catalogue(
                values,
                masks,
                fixed,
                kind,
                policy.allow_missing,
            ))
        }
    } else if matches!(
        kind,
        "KRAKEN_FISH" | "KRAKEN_FISH_TYPE_1" | "KRAKEN_FISH_TYPE_2"
    ) {
        Some(if let Some(scope) = scope {
            super::table::kraken::fine_proofs(
                masks,
                kind,
                &policy.all_kraken,
                policy.all_kraken_min,
                policy.all_kraken_digits,
                &|s| scope.might_match(s),
                cancelled,
            )
        } else {
            super::table::kraken::catalogue(
                masks,
                kind,
                &policy.all_kraken,
                policy.all_kraken_min,
                policy.all_kraken_digits,
                cancelled,
            )
        })
    } else if super::table::supports(kind) {
        // FindAllSteps delegates to TablingSolver, which reads the ordinary table option.
        Some(if let Some(scope) = scope {
            super::table::matching(
                values,
                masks,
                kind,
                &policy.table,
                &|s| scope.might_match(s),
                cancelled,
            )
        } else {
            super::table::catalogue(values, masks, kind, &policy.table, cancelled)
        })
    } else if als::supports(kind) {
        Some(if let Some(scope) = scope {
            als::fine_proofs(
                masks,
                kind,
                policy.all_overlap,
                policy.all_one_als,
                policy.all_forward_als,
                policy.all_als_length,
                &|s| scope.might_match(s),
                cancelled,
            )
        } else {
            als::catalogue(
                masks,
                kind,
                policy.all_overlap,
                policy.all_one_als,
                policy.all_forward_als,
                policy.all_als_length,
                cancelled,
            )
        })
    } else if matches!(kind, "TEMPLATE_SET" | "TEMPLATE_DEL") {
        Some(last_resort::templates_for(values, masks, kind, cancelled))
    } else {
        advanced::catalogue_with_options(values, masks, kind, &policy.advanced, cancelled)
    };
    let ending = if cancelled() {
        Ending::Cancelled
    } else if steps.is_some() {
        Ending::Stalled
    } else {
        Ending::Unsupported(kind.to_owned())
    };
    Ok(Path {
        ending,
        steps: steps.unwrap_or_default(),
        score: 0,
        difficulty: 0,
    })
}
