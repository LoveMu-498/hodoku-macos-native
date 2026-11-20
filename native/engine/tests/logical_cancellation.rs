// SPDX-License-Identifier: GPL-3.0-or-later
use hodoku_engine::phase5::{scoring::Policy, solve, Ending};
use std::cell::Cell;

#[test]
fn interrupted_last_rule_reports_cancellation_with_no_spurious_step() {
    for (kind, cutoff) in [("X_WING", 3), ("FORCING_NET", 7), ("UNIQUENESS_1", 7)] {
        let mut policy = Policy::defaults(false).unwrap();
        policy.rules.retain(|r| r.name == kind);
        assert_eq!(policy.rules.len(), 1, "{kind}");
        let polls = Cell::new(0);
        let path = solve(&[0; 81], &[511; 81], false, &policy, true, &|| {
            polls.set(polls.get() + 1);
            polls.get() >= cutoff
        })
        .unwrap();
        assert!(polls.get() >= cutoff, "{kind}");
        assert_eq!(path.ending, Ending::Cancelled, "{kind}");
        assert!(path.steps.is_empty(), "{kind}");
    }
}

#[test]
fn pre_cancelled_rating_takes_precedence_over_minimum_givens() {
    let policy = Policy::defaults(false).unwrap();
    let run = |stop: bool| solve(&[0; 81], &[511; 81], false, &policy, false, &|| stop).unwrap();
    assert_eq!(run(true).ending, Ending::Cancelled);
    assert_eq!(run(false).ending, Ending::Stalled);
}
