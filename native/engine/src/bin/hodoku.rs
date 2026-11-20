// SPDX-License-Identifier: GPL-3.0-or-later
//! One position per input line, so edited boards can be piped through the same solver as the app.
#[path = "hodoku/generate.rs"]
mod generate;
use hodoku_engine::phase5::{basic::BasicState, scoring::Policy, solve_board};
use std::fmt::Write;
use std::io::{self, BufRead};

const USAGE: &str = "hodoku {next|solve|rate|progress-score|catalogue KIND} [--progress]\nStandard input: grid[ TAB ordinary-candidate-masks[ TAB fixed-cells]].\nUse 81 digits (0 or . for blank), 81 three-digit hex masks, and 81 fixed flags (0/1).\nA grid alone is loaded in givens order. An explicit candidate map uses rebuilt queues.";

fn position(line: &str, policy: &Policy, mode: &str) -> Result<String, String> {
    let columns: Vec<_> = line.split('\t').collect();
    let grid = columns[0].as_bytes();
    if grid.len() != 81
        || columns.len() > 3
        || !grid.iter().all(|c| c.is_ascii_digit() || *c == b'.')
    {
        return Err("invalid grid".into());
    }
    let values = std::array::from_fn(|i| if grid[i] == b'.' { 0 } else { grid[i] - b'0' });
    let input = columns.get(1).copied().unwrap_or("");
    let from_clues = input.is_empty();
    let mut masks = [0; 81];
    if from_clues {
        for (i, value) in values.iter().enumerate() {
            if *value != 0
                && values[..i].iter().enumerate().any(|(j, d)| {
                    d == value
                        && (i / 9 == j / 9
                            || i % 9 == j % 9
                            || i / 27 == j / 27 && i % 9 / 3 == j % 9 / 3)
                })
            {
                return Err("duplicate given".into());
            }
        }
        masks = BasicState::from_clues(&values).masks;
    } else {
        if input.len() != 243 || !input.is_ascii() {
            return Err("expected 81 hex masks".into());
        }
        for (i, m) in masks.iter_mut().enumerate() {
            *m = u16::from_str_radix(&input[3 * i..3 * i + 3], 16)
                .map_err(|_| "invalid hex mask")?;
        }
    }
    let mut fixed = values.map(|d| d != 0);
    if let Some(flags) = columns.get(2) {
        if flags.len() != 81 {
            return Err("expected 81 fixed flags".into());
        }
        for (i, raw) in flags.bytes().enumerate() {
            fixed[i] = match raw {
                b'0' => false,
                b'1' if values[i] != 0 => true,
                _ => return Err("invalid fixed cell".into()),
            };
        }
    }
    let path = if mode == "catalogue" {
        hodoku_engine::phase5::catalogue::collect(&values, &masks, &fixed, policy, &|| false)
    } else {
        solve_board(
            &values,
            &masks,
            &fixed,
            from_clues,
            policy,
            matches!(mode, "next" | "progress-score"),
            &|| false,
        )
    }
    .map_err(|_| "invalid position or configuration")?;
    if mode == "progress-score" {
        let Some(proposed) = path.steps.first().filter(|s| s.kind != "GIVE_UP") else {
            return Ok(format!("@ {:?}", path.ending));
        };
        let state = if from_clues {
            BasicState::from_clues(&values)
        } else {
            BasicState::new(&values, &masks)
        };
        let config = Policy::defaults(true).map_err(|_| "invalid progress rules")?;
        let (ending, score) = hodoku_engine::phase5::scoring::progress_score(
            state,
            &fixed,
            proposed,
            &config,
            &|| false,
        )
        .map_err(|_| "invalid progress step")?;
        return Ok(format!(
            "@ {:?} {} {} {} {}",
            ending, proposed.kind, score.direct_singles, score.singles, score.score
        ));
    }
    let mut out = format!("@ {:?} {} {}", path.ending, path.difficulty, path.score);
    if mode != "rate" {
        let mut board = BasicState::new(&values, &masks);
        for step in &path.steps {
            if mode == "catalogue" {
                board = BasicState::new(&values, &masks);
            }
            if step.kind != "GIVE_UP" && !board.apply(step) {
                return Err("could not apply returned step".into());
            }
            write!(out, "\n{}\t", step.record()).map_err(|e| e.to_string())?;
            for d in board.values {
                out.push(char::from(b'0' + d));
            }
            out.push('\t');
            for m in board.masks {
                write!(out, "{m:03x}").map_err(|e| e.to_string())?;
            }
        }
    }
    Ok(out)
}

fn main() -> Result<(), String> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|v| v == "--help" || v == "-h") {
        println!("{USAGE}\n\n{}", generate::USAGE);
        return Ok(());
    }
    if args.first().is_some_and(|v| v == "generate") {
        return generate::run(&args[1..]);
    }
    if !(1..=2).contains(&args.len())
        || !matches!(
            args[0].as_str(),
            "next" | "solve" | "rate" | "progress-score" | "catalogue"
        )
        || (if args[0] == "catalogue" {
            args.len() != 2
        } else {
            args.get(1).is_some_and(|s| s != "--progress")
        })
    {
        return Err(USAGE.into());
    }
    let mut policy = Policy::defaults(args.get(1).is_some_and(|s| s == "--progress"))
        .map_err(|_| "invalid bundled rules")?;
    if args[0] == "catalogue" {
        policy.rules = vec![hodoku_engine::phase5::scoring::Rule {
            name: args[1].to_owned(),
            level: 0,
            score: 0,
        }];
    }
    for (index, line) in io::stdin().lock().lines().enumerate() {
        let line = line.map_err(|e| e.to_string())?;
        println!(
            "{}",
            position(&line, &policy, &args[0]).map_err(|e| format!("line {}: {e}", index + 1))?
        );
    }
    Ok(())
}
