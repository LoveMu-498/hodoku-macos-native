// SPDX-License-Identifier: GPL-3.0-or-later
// SudokuSolver.solve/getHint and SolutionType.getStepConfig, Bernhard Hobiger.
use crate::InvalidInput;
use std::collections::HashSet;

pub struct Rule {
    pub name: String,
    pub level: u8,
    pub score: i32,
}
pub struct Policy {
    /// Already sorted by solver index (or progress index) and filtered using that mode's enabled flag.
    pub rules: Vec<Rule>,
    pub table: super::table::Options,
    pub advanced: super::advanced::Options,
    pub all_table_als: bool,
    pub all_kraken: super::table::kraken::Options,
    pub all_kraken_min: u8,
    pub all_kraken_digits: u16,
    pub kraken: super::table::kraken::Options,
    pub all_overlap: bool,
    pub all_one_als: bool,
    pub all_forward_als: bool,
    pub all_als_length: usize,
    pub allow_missing: bool,
    pub allow_overlap: bool,
    pub only_one_als_per_step: bool,
    pub thresholds: [i32; 6],
    pub max_level: u8,
    pub reject_too_low: bool,
    pub training: HashSet<String>,
}
impl Policy {
    pub fn validate(&self) -> Result<(), InvalidInput> {
        let mut names = HashSet::new();
        if !(1..=5).contains(&self.max_level)
            || self.thresholds[0] != 0
            || self.thresholds.windows(2).any(|p| p[0] > p[1])
            || self
                .rules
                .iter()
                .any(|r| r.name.is_empty() || r.level > 5 || r.score < 0 || !names.insert(&r.name))
        {
            return Err(InvalidInput);
        }
        Ok(())
    }
}
#[derive(Debug)]
pub struct Rating {
    pub score: i32,
    pub level: u8,
    pub training_seen: bool,
}
impl Default for Rating {
    fn default() -> Self {
        Self {
            score: 0,
            level: 1,
            training_seen: false,
        }
    }
}
pub fn config_name(kind: &str) -> &str {
    match kind {
        "CONTINUOUS_NICE_LOOP" | "DISCONTINUOUS_NICE_LOOP" | "AIC" => "NICE_LOOP",
        "GROUPED_CONTINUOUS_NICE_LOOP" | "GROUPED_DISCONTINUOUS_NICE_LOOP" | "GROUPED_AIC" => {
            "GROUPED_NICE_LOOP"
        }
        "FORCING_CHAIN_CONTRADICTION" | "FORCING_CHAIN_VERITY" => "FORCING_CHAIN",
        "FORCING_NET_CONTRADICTION" | "FORCING_NET_VERITY" => "FORCING_NET",
        "KRAKEN_FISH_TYPE_1" | "KRAKEN_FISH_TYPE_2" => "KRAKEN_FISH",
        "DUAL_TWO_STRING_KITE" => "TWO_STRING_KITE",
        "DUAL_EMPTY_RECTANGLE" => "EMPTY_RECTANGLE",
        "SIMPLE_COLORS_TRAP" | "SIMPLE_COLORS_WRAP" => "SIMPLE_COLORS",
        "MULTI_COLORS_1" | "MULTI_COLORS_2" => "MULTI_COLORS",
        _ => kind,
    }
}
impl Rating {
    /// Java charges the requested config even when that search returns a subtype. Only a
    /// previously accepted training step can exempt this step from the early cut-off.
    pub fn observe(&mut self, rule: &Rule, returned: &str, policy: &Policy) -> bool {
        self.score = self.score.wrapping_add(rule.score);
        self.level = self.level.max(rule.level);
        if !self.training_seen
            && (self.level > policy.max_level
                || self.score >= policy.thresholds[usize::from(policy.max_level)])
        {
            return false;
        }
        self.training_seen |= policy.training.contains(config_name(returned));
        true
    }
    pub fn grade(&self, policy: &Policy) -> u8 {
        let mut grade = self.level;
        while grade < 5 && self.score > policy.thresholds[usize::from(grade)] {
            grade += 1;
        }
        grade
    }
    pub fn accepts(&self, grade: u8, policy: &Policy) -> bool {
        self.training_seen
            || (grade <= policy.max_level
                && (!policy.reject_too_low
                    || grade <= 1
                    || self.score >= policy.thresholds[usize::from(grade - 1)]))
    }
}

pub const DEFAULT_TABLE: &str = include_str!("default-rules.txt");
impl Policy {
    pub(super) fn empty() -> Self {
        Self {
            rules: Vec::new(),
            table: Default::default(),
            advanced: Default::default(),
            all_table_als: true,
            all_kraken: Default::default(),
            all_kraken_min: 2,
            all_kraken_digits: 511,
            kraken: Default::default(),
            all_overlap: true,
            all_one_als: true,
            all_forward_als: true,
            all_als_length: 6,
            allow_missing: true,
            allow_overlap: false,
            only_one_als_per_step: true,
            thresholds: [0, 800, 1000, 1600, 1800, i32::MAX],
            max_level: 5,
            reject_too_low: false,
            training: HashSet::new(),
        }
    }
    pub fn defaults(progress: bool) -> Result<Self, InvalidInput> {
        let mut ordered = Vec::new();
        for line in DEFAULT_TABLE.lines() {
            let f: Vec<_> = line.split_whitespace().collect();
            if f[if progress { 8 } else { 6 }] != "1" {
                continue;
            }
            let parse = |i: usize| f[i].parse::<i32>().map_err(|_| InvalidInput);
            ordered.push((
                parse(if progress { 2 } else { 1 })?,
                Rule {
                    name: f[0].to_owned(),
                    level: parse(3)? as u8,
                    score: parse(4)?,
                },
            ));
        }
        ordered.sort_by_key(|(idx, _)| *idx);
        Ok(Self {
            rules: ordered.into_iter().map(|(_, r)| r).collect(),
            ..Self::empty()
        })
    }
}

/// SudokuSolver.getProgressScore applies the proposed step before counting newly
/// unlocked singles. The consecutive prefix ends at the first non-single.
pub struct ProgressScore {
    pub singles: usize,
    pub direct_singles: usize,
    pub score: i32,
}

pub fn progress_score(
    mut state: super::basic::BasicState,
    fixed: &[bool; 81],
    proposed: &super::Step,
    policy: &Policy,
    cancelled: &dyn Fn() -> bool,
) -> Result<(super::Ending, ProgressScore), InvalidInput> {
    if !state.apply(proposed) {
        return Err(InvalidInput);
    }
    let placed = if matches!(
        proposed.kind,
        "TEMPLATE_SET" | "FORCING_CHAIN_VERITY" | "FORCING_NET_VERITY"
    ) {
        proposed.indices.len()
    } else {
        0
    };
    let path = super::solve_state(state, fixed, policy, false, false, cancelled)?;
    let mut result = ProgressScore {
        singles: placed,
        direct_singles: placed,
        score: 0,
    };
    let mut direct = true;
    for step in &path.steps {
        if matches!(step.kind, "FULL_HOUSE" | "HIDDEN_SINGLE" | "NAKED_SINGLE") {
            result.singles += 1;
            if direct {
                result.direct_singles += 1;
            }
        } else {
            direct = false;
        }
        if let Some(rule) = policy
            .rules
            .iter()
            .find(|r| r.name == config_name(step.kind))
        {
            result.score = result.score.wrapping_add(rule.score);
        }
    }
    Ok((path.ending, result))
}
