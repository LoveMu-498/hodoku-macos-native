// SPDX-License-Identifier: GPL-3.0-or-later
//! Logical solution paths and difficulty as used by SudokuSolver.
pub mod advanced;
pub mod als;
pub mod basic;
pub mod catalogue;
mod ffi;
pub mod generation;
mod last_resort;
pub mod scoring;
pub mod table;
pub mod uniqueness;

use crate::board::Board;
use crate::InvalidInput;
use scoring::{Policy, Rating};

/// Base/cover combinations and ALS edges visit millions of very small nodes. Keep
/// the Swift callback out of most visits and remember a stop while unwinding.
struct NodePoll<'a> {
    query: &'a dyn Fn() -> bool,
    remaining: u8,
    stopped: bool,
}

impl<'a> NodePoll<'a> {
    fn new(query: &'a dyn Fn() -> bool) -> Self {
        Self {
            query,
            remaining: 0,
            stopped: false,
        }
    }

    fn cancelled(&mut self) -> bool {
        if self.remaining == 0 {
            self.stopped = self.stopped || (self.query)();
            self.remaining = 64;
        }
        self.remaining -= 1;
        self.stopped
    }
}

/// Preserve the Java SolutionStep order, including duplicate deletions belonging to two houses.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Step {
    pub kind: &'static str,
    pub indices: Vec<u8>,
    pub values: Vec<u8>,
    pub deletes: Vec<(u8, u8)>,
    pub fins: Vec<(u8, u8)>,
    pub endo_fins: Vec<(u8, u8)>,
    pub bases: Vec<u8>,
    pub covers: Vec<u8>,
    pub chains: Vec<Vec<i32>>,
    pub potential: Vec<(u8, u8)>,
    pub cannibalistic: Vec<(u8, u8)>,
    pub house: Option<u8>,
    pub entity: Option<(u8, i16)>,
    pub siamese: bool,
    pub potential_cannibalistic: Vec<(u8, u8)>,
    pub subtype: Option<&'static str>,
    pub colors: Vec<(u8, i32)>,
    pub alses: Vec<(Vec<u8>, Vec<u8>)>,
    pub restricted: Vec<(usize, usize, u8, u8, u8)>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ending {
    Solved,
    Stalled,
    Contradiction,
    Unrated(String),
    Unsupported(String),
    Rejected,
    Cancelled,
    FirstStep,
}

#[derive(Clone, Debug)]
pub struct Path {
    pub ending: Ending,
    pub difficulty: u8,
    pub score: i32,
    pub steps: Vec<Step>,
}

fn basic_kind(kind: &str) -> bool {
    matches!(
        kind,
        "FULL_HOUSE"
            | "NAKED_SINGLE"
            | "HIDDEN_SINGLE"
            | "LOCKED_PAIR"
            | "LOCKED_TRIPLE"
            | "LOCKED_CANDIDATES_1"
            | "LOCKED_CANDIDATES_2"
            | "NAKED_PAIR"
            | "NAKED_TRIPLE"
            | "NAKED_QUADRUPLE"
            | "HIDDEN_PAIR"
            | "HIDDEN_TRIPLE"
            | "HIDDEN_QUADRUPLE"
    )
}

fn consistent(values: &[u8; 81], masks: &[u16; 81]) -> bool {
    let mut covered = [0u16; 27];
    for cell in 0..81 {
        let value = values[cell];
        if value == 0 && masks[cell] == 0 {
            return false;
        }
        let allowed = if value == 0 {
            masks[cell]
        } else {
            1 << (value - 1)
        };
        for house in crate::board::houses(cell) {
            covered[house] |= allowed;
        }
    }
    covered.iter().all(|&mask| mask == 511)
}

pub fn solve(
    values: &[u8; 81],
    masks: &[u16; 81],
    from_clues: bool,
    policy: &Policy,
    first_only: bool,
    cancelled: &dyn Fn() -> bool,
) -> Result<Path, InvalidInput> {
    solve_board(
        values,
        masks,
        &values.map(|v| v != 0),
        from_clues,
        policy,
        first_only,
        cancelled,
    )
}

pub fn solve_board(
    values: &[u8; 81],
    masks: &[u16; 81],
    fixed: &[bool; 81],
    from_clues: bool,
    policy: &Policy,
    first_only: bool,
    cancelled: &dyn Fn() -> bool,
) -> Result<Path, InvalidInput> {
    policy.validate()?;
    let (legal, _) = Board::from_snapshot(values, None)?;
    if from_clues && *masks != legal.masks {
        return Err(InvalidInput);
    }
    Board::from_snapshot(values, Some(masks))?;
    if !consistent(values, masks) {
        return Err(InvalidInput);
    }
    let state = if from_clues {
        basic::BasicState::from_clues(values)
    } else {
        basic::BasicState::new(values, masks)
    };
    solve_state(state, fixed, policy, first_only, true, cancelled)
}

fn solve_state(
    mut state: basic::BasicState,
    fixed: &[bool; 81],
    policy: &Policy,
    first_only: bool,
    enforce_minimum: bool,
    cancelled: &dyn Fn() -> bool,
) -> Result<Path, InvalidInput> {
    let values = state.values;
    let masks = state.masks;
    let mut valid = None;
    let mut valid_givens = None;
    let mut rating = Rating::default();
    let mut steps = Vec::new();
    let mut ending = Ending::Stalled;
    if first_only || !enforce_minimum || state.remaining <= 71 {
        'search: loop {
            if cancelled() {
                ending = Ending::Cancelled;
                break;
            }
            if !state.values.contains(&0) {
                ending = Ending::Solved;
                break;
            }
            for rule in &policy.rules {
                if cancelled() {
                    ending = Ending::Cancelled;
                    break 'search;
                }
                let kind = rule.name.as_str();
                let next = if basic_kind(kind) {
                    state.first(kind)
                } else if uniqueness::supports(kind) || kind == "BUG_PLUS_1" {
                    let verified = *valid.get_or_insert_with(|| {
                        crate::count_solutions(&values, Some(&masks), 1, 1_000_000, cancelled)
                            .ok()
                            .is_some_and(|r| r.solution.is_some())
                    });
                    if !verified {
                        continue;
                    }
                    if kind.starts_with("AVOIDABLE_RECTANGLE") {
                        let givens = std::array::from_fn(|i| if fixed[i] { values[i] } else { 0 });
                        if !*valid_givens.get_or_insert_with(|| {
                            crate::count_solutions(&givens, None, 1, 1_000_000, cancelled)
                                .ok()
                                .is_some_and(|r| r.solution.is_some())
                        }) {
                            continue;
                        }
                    }
                    if kind == "BUG_PLUS_1" {
                        advanced::first_with_options(
                            &state.values,
                            &state.masks,
                            kind,
                            &policy.advanced,
                            cancelled,
                        )
                    } else {
                        uniqueness::first(
                            &state.values,
                            &state.masks,
                            fixed,
                            kind,
                            policy.allow_missing,
                        )
                    }
                } else if kind == "KRAKEN_FISH" {
                    match table::kraken::first(&state.masks, &policy.kraken, cancelled) {
                        Ok(step) => step,
                        Err(_) => {
                            ending = Ending::Unrated(kind.to_owned());
                            break 'search;
                        }
                    }
                } else if table::supports(kind) {
                    table::first_with_options(
                        &state.values,
                        &state.masks,
                        kind,
                        &policy.table,
                        cancelled,
                    )
                } else if als::supports(kind) {
                    als::first_with_options(
                        &state.masks,
                        kind,
                        policy.allow_overlap,
                        policy.only_one_als_per_step,
                        cancelled,
                    )
                } else if advanced::supports(kind) {
                    advanced::first_with_options(
                        &state.values,
                        &state.masks,
                        kind,
                        &policy.advanced,
                        cancelled,
                    )
                } else if last_resort::supports(kind) {
                    last_resort::first(&state.values, &state.masks, kind, cancelled)
                } else {
                    ending = Ending::Unsupported(rule.name.clone());
                    break 'search;
                };
                let Some(step) = next else { continue };
                if cancelled() {
                    ending = Ending::Cancelled;
                    break 'search;
                }
                if !rating.observe(rule, step.kind, policy) {
                    ending = Ending::Rejected;
                    break 'search;
                }
                if step.kind == "GIVE_UP" {
                    steps.push(step);
                    break 'search;
                }
                if !state.apply(&step) {
                    return Err(InvalidInput);
                }
                steps.push(step);
                if first_only {
                    ending = Ending::FirstStep;
                    break 'search;
                }
                if !consistent(&state.values, &state.masks) {
                    ending = Ending::Contradiction;
                    break 'search;
                }
                continue 'search;
            }
            break;
        }
    }
    let grade = rating.grade(policy);
    // An interrupted rule can return no step. This also covers a final
    // uniqueness rule that bypassed the remaining search after its count.
    if cancelled() {
        ending = Ending::Cancelled;
    } else if ending == Ending::Solved && !rating.accepts(grade, policy) {
        ending = Ending::Rejected;
    }
    Ok(Path {
        difficulty: grade,
        score: rating.score,
        steps,
        ending,
    })
}
