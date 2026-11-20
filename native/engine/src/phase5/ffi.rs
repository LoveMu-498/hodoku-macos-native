// SPDX-License-Identifier: GPL-3.0-or-later
use super::{
    scoring::{Policy, Rule},
    Ending, Path, Step,
};
use crate::InvalidInput;
use std::{ffi::c_void, fmt::Display, panic::catch_unwind};

fn nums<T: Display>(numbers: &[T]) -> String {
    numbers
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(",")
}
fn pairs(candidates: &[(u8, u8)]) -> String {
    nums(
        &candidates
            .iter()
            .map(|&(c, d)| u16::from(c) * 10 + u16::from(d))
            .collect::<Vec<_>>(),
    )
}
impl Step {
    /// Numeric fields preserve both ordering and duplicates. One UTF-8 record per actual step.
    pub fn record(&self) -> String {
        [
            self.kind.to_string(),
            nums(&self.indices),
            nums(&self.values),
            pairs(&self.deletes),
            pairs(&self.fins),
            pairs(&self.endo_fins),
            nums(&self.bases),
            nums(&self.covers),
            self.chains
                .iter()
                .map(|c| nums(c))
                .collect::<Vec<_>>()
                .join(";"),
            pairs(&self.potential),
            pairs(&self.cannibalistic),
            self.house.map(|n| n.to_string()).unwrap_or_default(),
            super::scoring::config_name(self.kind).to_owned(),
            self.colors
                .iter()
                .map(|(c, k)| format!("{c}:{k}"))
                .collect::<Vec<_>>()
                .join(","),
            self.alses
                .iter()
                .map(|(i, v)| format!("{}:{}", nums(i), nums(v)))
                .collect::<Vec<_>>()
                .join(";"),
            self.restricted
                .iter()
                .map(|(a, b, c, d, e)| format!("{a},{b},{c},{d},{e}"))
                .collect::<Vec<_>>()
                .join(";"),
            self.entity
                .map(|(kind, number)| format!("{kind},{number}"))
                .unwrap_or_default(),
            self.subtype.unwrap_or_default().to_owned(),
            u8::from(self.siamese).to_string(),
            pairs(&self.potential_cannibalistic),
        ]
        .join("|")
    }
}
fn records(path: &mut Path, catalogue: bool, cancelled: &dyn Fn() -> bool) -> String {
    let mut data = String::new();
    for (i, step) in path.steps.iter().enumerate() {
        // A catalogue is published as a whole. A timed-out solution
        // path, in contrast, still carries its completed prefix.
        if catalogue && i % 32 == 0 && cancelled() {
            path.ending = Ending::Cancelled;
            break;
        }
        if !data.is_empty() {
            data.push('\n');
        }
        data.push_str(&step.record());
    }
    if catalogue && cancelled() {
        path.ending = Ending::Cancelled;
    }
    match &path.ending {
        Ending::Cancelled if catalogue => data.clear(),
        Ending::Unsupported(name) | Ending::Unrated(name) => {
            if !data.is_empty() {
                data.push('\n');
            }
            data.push('@');
            data.push_str(name);
        }
        _ => {}
    }
    data
}

impl Policy {
    pub fn read(
        input: &str,
        thresholds: [i32; 6],
        max_level: u8,
        reject_too_low: bool,
    ) -> Result<Self, InvalidInput> {
        let mut policy = Self {
            thresholds,
            max_level,
            reject_too_low,
            ..Self::empty()
        };
        for row in input.lines() {
            if let Some(setting) = row.strip_prefix('%') {
                let (key, value) = setting.split_once('=').ok_or(InvalidInput)?;
                match key {
                    "allowAlsInTablingChains" => {
                        policy.table.allow_als = value.parse().map_err(|_| InvalidInput)?
                    }
                    "allStepsAllowAlsInTablingChains" => {
                        policy.all_table_als = value.parse().map_err(|_| InvalidInput)?
                    }
                    "allStepsKrakenMaxFishType" => {
                        policy.all_kraken.max_kind = value.parse().map_err(|_| InvalidInput)?
                    }
                    "allStepsKrakenMinFishSize" => {
                        policy.all_kraken_min = value.parse().map_err(|_| InvalidInput)?
                    }
                    "allStepsKrakenMaxFishSize" => {
                        policy.all_kraken.max_size = value.parse().map_err(|_| InvalidInput)?
                    }
                    "allStepsMaxKrakenFins" => {
                        policy.all_kraken.max_fins = value.parse().map_err(|_| InvalidInput)?
                    }
                    "allStepsMaxKrakenEndoFins" => {
                        policy.all_kraken.max_endo = value.parse().map_err(|_| InvalidInput)?
                    }
                    "allStepsKrakenFishCandidates" => {
                        if value.len() != 9 || !value.bytes().all(|c| c == b'0' || c == b'1') {
                            return Err(InvalidInput);
                        }
                        policy.all_kraken_digits = value
                            .bytes()
                            .enumerate()
                            .fold(0, |m, (i, v)| m | (u16::from(v == b'1') << i));
                    }
                    "allowDualsAndSiamese" => {
                        policy.advanced.set(key, value)?;
                        policy.kraken.siamese = policy.advanced.duals;
                    }
                    "maxTableEntryLength" => {
                        policy.table.max_entries = value.parse().map_err(|_| InvalidInput)?
                    }
                    "anzTableLookAhead" => {
                        policy.table.look_ahead = value.parse().map_err(|_| InvalidInput)?
                    }
                    "onlyOneChainPerStep" => {
                        policy.table.only_one_chain = value.parse().map_err(|_| InvalidInput)?
                    }
                    "krakenMaxFishType" => {
                        policy.kraken.max_kind = value.parse().map_err(|_| InvalidInput)?
                    }
                    "krakenMaxFishSize" => {
                        policy.kraken.max_size = value.parse().map_err(|_| InvalidInput)?
                    }
                    "maxKrakenFins" => {
                        policy.kraken.max_fins = value.parse().map_err(|_| InvalidInput)?
                    }
                    "maxKrakenEndoFins" => {
                        policy.kraken.max_endo = value.parse().map_err(|_| InvalidInput)?
                    }
                    "allStepsAllowAlsOverlap" => {
                        policy.all_overlap = value.parse().map_err(|_| InvalidInput)?
                    }
                    "allStepsOnlyOneAlsPerStep" => {
                        policy.all_one_als = value.parse().map_err(|_| InvalidInput)?
                    }
                    "allStepsAlsChainForwardOnly" => {
                        policy.all_forward_als = value.parse().map_err(|_| InvalidInput)?
                    }
                    "allStepsAlsChainLength" => {
                        policy.all_als_length = value.parse().map_err(|_| InvalidInput)?
                    }
                    _ => policy.advanced.set(key, value)?,
                }
                continue;
            }
            if let Some(key) = row.strip_prefix('@') {
                policy.training.insert(key.to_owned());
                continue;
            }
            let fields: Vec<_> = row.split(',').collect();
            if fields.len() != 4
                || !fields[0]
                    .bytes()
                    .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == b'_')
            {
                return Err(InvalidInput);
            }
            let (Ok(level), Ok(score)) = (fields[1].parse(), fields[2].parse()) else {
                return Err(InvalidInput);
            };
            match fields[3] {
                "1" => {
                    policy.training.insert(fields[0].to_owned());
                }
                "0" => {}
                _ => return Err(InvalidInput),
            }
            policy.rules.push(Rule {
                name: fields[0].to_owned(),
                level,
                score,
            });
        }
        for options in [&mut policy.kraken, &mut policy.all_kraken] {
            options.allow_als = policy.table.allow_als;
            options.max_entries = policy.table.max_entries;
        }
        policy.validate()?;
        Ok(policy)
    }
}
#[repr(C)]
pub struct LogicalResult {
    ending: u32,
    difficulty: u32,
    score: i32,
}
#[no_mangle]
pub unsafe extern "C" fn hodoku_logic_v1(
    values: *const u8,
    masks: *const u16,
    fixed: *const u8,
    cells: usize,
    config: *const u8,
    length: usize,
    thresholds: *const i32,
    levels: usize,
    max_level: u32,
    flags: u32,
    context: *mut c_void,
    cancel: Option<extern "C" fn(*mut c_void) -> u8>,
    receive: Option<extern "C" fn(*mut c_void, *const u8, usize)>,
    result: *mut LogicalResult,
) -> i32 {
    if cells != 81
        || levels != 6
        || max_level > 5
        || flags > 127
        || length > 65536
        || values.is_null()
        || masks.is_null()
        || fixed.is_null()
        || config.is_null()
        || thresholds.is_null()
        || result.is_null()
    {
        return 1;
    }
    catch_unwind(|| {
        // SAFETY: header requires live aligned buffers of the validated sizes until return.
        let (v, m, fix, c, t) = unsafe {
            (
                &*values.cast::<[u8; 81]>(),
                &*masks.cast::<[u16; 81]>(),
                &*fixed.cast::<[u8; 81]>(),
                std::slice::from_raw_parts(config, length),
                *thresholds.cast::<[i32; 6]>(),
            )
        };
        let Ok(text) = std::str::from_utf8(c) else {
            return 1;
        };
        let Ok(mut policy) = Policy::read(text, t, max_level as u8, flags & 2 != 0) else {
            return 1;
        };
        policy.allow_missing = flags & 8 == 0;
        policy.allow_overlap = flags & 16 != 0;
        policy.only_one_als_per_step = flags & 32 == 0;
        if fix
            .iter()
            .enumerate()
            .any(|(i, &x)| x > 1 || (x != 0 && v[i] == 0))
        {
            return 1;
        }
        let fixed = fix.map(|v| v != 0);
        let cancelled = || cancel.is_some_and(|f| f(context) != 0);
        let catalogue = flags & 64 != 0;
        let search = if catalogue {
            super::catalogue::collect(v, m, &fixed, &policy, &cancelled)
        } else {
            super::solve_board(
                v,
                m,
                &fixed,
                flags & 1 != 0,
                &policy,
                flags & 4 != 0,
                &cancelled,
            )
        };
        let Ok(mut path) = search else { return 1 };
        if let Some(f) = receive {
            let data = records(&mut path, catalogue, &cancelled);
            f(context, data.as_ptr(), data.len());
        }
        let ending = match path.ending {
            Ending::Solved => 0,
            Ending::Stalled => 1,
            Ending::Unsupported(_) => 2,
            Ending::Unrated(_) => 7,
            Ending::Contradiction => 6,
            Ending::Rejected => 3,
            Ending::Cancelled => 4,
            Ending::FirstStep => 5,
        };
        // SAFETY: result is writable, non-null and owned by the caller.
        unsafe {
            result.write(LogicalResult {
                ending,
                difficulty: path.difficulty.into(),
                score: path.score,
            });
        }
        0
    })
    .unwrap_or(2)
}

#[no_mangle]
pub unsafe extern "C" fn hodoku_logic_default_rules_v1(length: *mut usize) -> *const u8 {
    const RULES: &str = include_str!("default-rules.txt");
    if length.is_null() {
        return std::ptr::null();
    }
    // SAFETY: caller supplies a writable size_t and the immutable bytes have static lifetime.
    unsafe { length.write(RULES.len()) };
    RULES.as_ptr()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    #[test]
    fn cancellation_during_catalogue_encoding_discards_partial_output() {
        let mut path = Path {
            ending: Ending::Stalled,
            steps: vec![
                Step {
                    kind: "AIC",
                    ..Default::default()
                };
                80
            ],
            score: 0,
            difficulty: 0,
        };
        let seen = Cell::new(false);
        let data = records(&mut path, true, &|| seen.replace(true));
        assert_eq!(path.ending, Ending::Cancelled);
        assert!(data.is_empty());

        // A timed-out solve still publishes every committed step in its path.
        let data = records(&mut path, false, &|| true);
        assert_eq!(data.lines().count(), 80);
    }
}
