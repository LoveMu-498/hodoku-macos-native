// SPDX-License-Identifier: GPL-3.0-or-later
use hodoku_engine::{count_solutions, InvalidInput, Termination};
use std::{
    cell::Cell,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
};

const UNIQUE: &str =
    "..15............32...............2.9.5...3......7..8..27.....4.3...9.......6..5..";
const MULTIPLE: &str =
    "1..2..3...2.1.........3...1....1.2.3..1...4....2.4...........1.2.........1.......";
const SOLVED: &str =
    "534678912672195348198342567859761423426853791713924856961537284287419635345286179";

fn values(input: &str) -> [u8; 81] {
    let mut out = [0; 81];
    for (idx, b) in input.bytes().enumerate() {
        if b != b'.' {
            out[idx] = b - b'0';
        }
    }
    out
}

#[test]
fn candidate_deletion_changes_the_set_of_solutions() {
    // Removing both 1 and 2 from the solved grid permits a global swap.
    let mut clues = values(SOLVED);
    let mut masks = [0; 81];
    for i in 0..81 {
        if clues[i] <= 2 {
            clues[i] = 0;
            masks[i] = 3;
        }
    }
    assert_eq!(
        count_solutions(&clues, None, 1, 100, &|| false)
            .unwrap()
            .termination,
        Termination::SolutionBound
    );
    let one = SOLVED.find('1').unwrap();
    masks[one] = 1;
    let r = count_solutions(&clues, Some(&masks), 1, 100, &|| false).unwrap();
    assert_eq!(r.solution, Some(values(SOLVED)));
    masks[one] = 0;
    let r = count_solutions(&clues, Some(&masks), 1, 100, &|| false).unwrap();
    assert_eq!(
        (r.termination, r.count, r.solution),
        (Termination::Exhausted, 0, None)
    );
}

#[test]
fn an_existing_zero_domain_still_honors_the_guess_budget() {
    let mut masks = [511; 81];
    masks[0] = 0;
    let zero = count_solutions(&[0; 81], Some(&masks), 1, 0, &|| false).unwrap();
    assert_eq!(
        (zero.termination, zero.count, zero.tries),
        (Termination::Limit, 0, 0)
    );
    let allowed = count_solutions(&[0; 81], Some(&masks), 1, 1, &|| false).unwrap();
    assert_eq!(
        (allowed.termination, allowed.count, allowed.tries),
        (Termination::Exhausted, 0, 0)
    );
}

#[test]
fn limit_after_one_solution_cannot_prove_uniqueness() {
    let r = count_solutions(&values(MULTIPLE), None, 1, 29, &|| false).unwrap();
    assert_eq!(
        (r.termination, r.count, r.tries, r.solution),
        (Termination::Limit, 1, 29, None)
    );
    let r = count_solutions(&values(UNIQUE), None, 1, 1000000, &|| false).unwrap();
    assert_eq!(
        (r.termination, r.count, r.tries),
        (Termination::Exhausted, 1, 4)
    );
    assert!(r.solution.is_some());
}

#[test]
fn empty_grid_and_conflicting_clues_have_distinct_outcomes() {
    let r = count_solutions(&[0; 81], None, 1, 1000000, &|| false).unwrap();
    assert_eq!(
        (r.termination, r.count, r.solution),
        (Termination::SolutionBound, 2, None)
    );
    let mut duplicate = values(SOLVED);
    duplicate[0] = duplicate[1];
    assert_eq!(
        count_solutions(&duplicate, None, 1, 1000000, &|| false),
        Err(InvalidInput)
    );
    let mut masks = [0; 81];
    masks[0] = 512;
    assert_eq!(
        count_solutions(&values(SOLVED), Some(&masks), 1, 100, &|| false),
        Err(InvalidInput)
    );
}

#[test]
fn cancellation_inside_live_search_keeps_partial_count_and_allows_fresh_request() {
    let cancel = AtomicBool::new(false);
    let (entered_tx, entered_rx) = mpsc::sync_channel(0);
    let (resume_tx, resume_rx) = mpsc::sync_channel(0);
    thread::scope(|scope| {
        let token = &cancel;
        let worker = scope.spawn(move || {
            let checks = Cell::new(0);
            count_solutions(&values(MULTIPLE), None, 1000000, 1000000, &|| {
                checks.set(checks.get() + 1);
                if checks.get() == 300 {
                    entered_tx.send(()).unwrap();
                    resume_rx.recv().unwrap();
                }
                token.load(Ordering::Relaxed)
            })
            .unwrap()
        });
        entered_rx.recv().unwrap();
        cancel.store(true, Ordering::Relaxed);
        resume_tx.send(()).unwrap();
        let r = worker.join().unwrap();
        assert_eq!((r.termination, r.solution), (Termination::Cancelled, None));
        assert!(r.count > 0 && r.tries > 29);
    });
    let next = count_solutions(&values(SOLVED), None, 1, 0, &|| false).unwrap();
    assert_eq!(next.solution, Some(values(SOLVED)));
}
