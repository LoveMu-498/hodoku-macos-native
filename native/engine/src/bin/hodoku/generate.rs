// SPDX-License-Identifier: GPL-3.0-or-later
use hodoku_engine::phase5::{
    basic::BasicState,
    generation::{generate_clues, GenerationStop},
    scoring::{config_name, Policy},
    solve, Ending,
};
use std::collections::BTreeSet;
use std::fmt::Write;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const USAGE: &str = "hodoku generate [--level 1..5] [--mode playing|learning|practising]\n    [--training KIND[,KIND...]] [--seed I64] [--attempts N] [--seconds N] [--pattern 81-BITS]\nOutputs one TSV row: mode, effective requested level, training, actual level, score, clues, starting values, ordinary masks, user masks.";

struct Request {
    mode: String,
    level: u8,
    training: BTreeSet<String>,
    seed: i64,
    attempts: u32,
    timeout: Duration,
    pattern: Option<[u8; 81]>,
}
impl Request {
    fn read(args: &[String]) -> Result<Self, String> {
        let mut options = Self {
            mode: "PLAYING".into(),
            level: 1,
            training: BTreeSet::new(),
            seed: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_err(|e| e.to_string())?
                .as_nanos() as i64,
            attempts: 20001,
            timeout: Duration::from_secs(60),
            pattern: None,
        };
        let mut words = args.iter();
        while let Some(key) = words.next() {
            let raw = words
                .next()
                .ok_or_else(|| format!("missing value for {key}"))?;
            let error = || format!("invalid {key}: {raw}");
            match key.as_str() {
                "--mode" => {
                    options.mode = raw.to_ascii_uppercase();
                    if !matches!(options.mode.as_str(), "PLAYING" | "PRACTISING" | "LEARNING") {
                        return Err(error());
                    }
                }
                "--level" => {
                    options.level = raw.parse().map_err(|_| error())?;
                    if !(1..=5).contains(&options.level) {
                        return Err(error());
                    }
                }
                "--training" => {
                    for name in raw.split(',') {
                        if name.is_empty()
                            || !name
                                .bytes()
                                .all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
                        {
                            return Err(error());
                        }
                        options.training.insert(config_name(name).to_owned());
                    }
                }
                "--seed" => options.seed = raw.parse().map_err(|_| error())?,
                "--attempts" => options.attempts = raw.parse().map_err(|_| error())?,
                "--seconds" => {
                    options.timeout = Duration::from_secs(raw.parse().map_err(|_| error())?)
                }
                "--pattern" => {
                    if raw.len() != 81 || !raw.bytes().all(|v| matches!(v, b'0' | b'1')) {
                        return Err(error());
                    }
                    options.pattern = Some(std::array::from_fn(|i| raw.as_bytes()[i] - b'0'));
                }
                _ => return Err(format!("unknown option {key}\n{USAGE}")),
            }
        }
        if options.mode == "PLAYING" {
            options.training.clear()
        } else if options.training.is_empty() {
            return Err("choose a training technique with --training".into());
        }
        Ok(options)
    }
}

pub fn run(args: &[String]) -> Result<(), String> {
    if args.len() == 1 && matches!(args[0].as_str(), "-h" | "--help") {
        println!("{USAGE}");
        return Ok(());
    }
    let request = Request::read(args)?;
    let mut effective_level = request.level;
    let mut policy = Policy::defaults(false).map_err(|_| "invalid default solver configuration")?;
    let learning = request.mode == "LEARNING";
    policy.reject_too_low = true;
    for name in &request.training {
        let rule = policy
            .rules
            .iter()
            .find(|rule| rule.name == *name)
            .ok_or_else(|| format!("training technique is disabled or unknown: {name}"))?;
        effective_level = effective_level.max(rule.level);
        policy.training.insert(name.clone());
    }
    policy.max_level = if learning { 5 } else { effective_level };
    let began = Instant::now();
    let expired = || began.elapsed() >= request.timeout;
    let limit = "generation search limit reached";
    for attempt in 0..request.attempts {
        let clues = generate_clues(
            request.seed.wrapping_add(i64::from(attempt)),
            true,
            request.pattern.as_ref(),
            1024,
            &expired,
        )
        .map_err(|stop| match stop {
            GenerationStop::PatternRejected => "pattern does not give a unique solution",
            GenerationStop::SearchLimit | GenerationStop::Cancelled => limit,
        })?;
        let mut board = BasicState::from_clues(&clues);
        let path = solve(&clues, &board.masks, true, &policy, false, &expired)
            .map_err(|_| "invalid generated board or configuration")?;
        if expired() {
            return Err(limit.into());
        }
        if path.ending != Ending::Solved || !learning && path.difficulty != effective_level {
            continue;
        }
        if !request.training.is_empty() {
            let Some(first) = path
                .steps
                .iter()
                .position(|s| policy.training.contains(config_name(s.kind)))
            else {
                continue;
            };
            if learning {
                for step in &path.steps[..first] {
                    if !board.apply(step) {
                        return Err("invalid training prefix".into());
                    }
                }
            }
        }
        let digits = |values: &[u8; 81]| {
            values
                .iter()
                .map(|v| char::from(b'0' + *v))
                .collect::<String>()
        };
        let mut masks = String::with_capacity(243);
        for mask in board.masks {
            write!(masks, "{mask:03x}").map_err(|e| e.to_string())?;
        }
        println!(
            "{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}",
            request.mode,
            effective_level,
            request
                .training
                .iter()
                .cloned()
                .collect::<Vec<_>>()
                .join(","),
            path.difficulty,
            path.score,
            digits(&clues),
            digits(&board.values),
            masks,
            "000".repeat(81)
        );
        return Ok(());
    }
    Err(limit.into())
}
