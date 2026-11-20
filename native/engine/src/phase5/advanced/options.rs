// SPDX-License-Identifier: GPL-3.0-or-later
use crate::InvalidInput;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Options {
    pub fine_scope: Option<FineScope>,
    pub restrict_chain: bool,
    pub chain_length: usize,
    pub two_candidate_rectangles: bool,
    pub duals: bool,
    pub max_fins: u32,
    pub max_endo: u32,
    pub templates: bool,
    pub one_fish: bool,
    pub all_fish: bool,
    pub all_min_size: u32,
    pub all_max_size: u32,
    pub all_fish_type: usize,
    pub all_fins: u32,
    pub all_endo: u32,
    pub all_templates: bool,
    pub all_digits: u16,
}
impl Default for Options {
    fn default() -> Self {
        Self {
            fine_scope: None,
            restrict_chain: true,
            chain_length: 20,
            two_candidate_rectangles: false,
            duals: false,
            max_fins: 5,
            max_endo: 2,
            templates: true,
            one_fish: true,
            all_fish: true,
            all_min_size: 2,
            all_max_size: 4,
            all_fish_type: 1,
            all_fins: 5,
            all_endo: 2,
            all_templates: true,
            all_digits: 511,
        }
    }
}
impl Options {
    pub fn set(&mut self, key: &str, value: &str) -> Result<(), InvalidInput> {
        let boolean = || match value {
            "true" | "1" => Ok(true),
            "false" | "0" => Ok(false),
            _ => Err(InvalidInput),
        };
        let integer = |lo: u32, hi: u32| {
            value
                .parse::<u32>()
                .ok()
                .filter(|v| (lo..=hi).contains(v))
                .ok_or(InvalidInput)
        };
        match key {
            "fineProofCells" | "fineProofDigits" => {
                self.fine_scope = Some(FineScope::parse(value, key == "fineProofDigits")?)
            }
            "restrictChainSize" => self.restrict_chain = boolean()?,
            "restrictChainLength" => self.chain_length = integer(0, 161)? as usize,
            "allowErsWithOnlyTwoCandidates" => self.two_candidate_rectangles = boolean()?,
            "allowDualsAndSiamese" => self.duals = boolean()?,
            "maxFins" => self.max_fins = integer(0, 81)?,
            "maxEndoFins" => self.max_endo = integer(0, 81)?,
            "checkTemplates" => self.templates = boolean()?,
            "onlyOneFishPerStep" => self.one_fish = boolean()?,
            "allStepsSearchFish" => self.all_fish = boolean()?,
            "allStepsMinFishSize" => self.all_min_size = integer(2, 7)?,
            "allStepsMaxFishSize" => self.all_max_size = integer(2, 7)?,
            "allStepsMaxFishType" => self.all_fish_type = integer(0, 2)? as usize,
            "allStepsMaxFins" => self.all_fins = integer(0, 81)?,
            "allStepsMaxEndoFins" => self.all_endo = integer(0, 81)?,
            "allStepsCheckTemplates" => self.all_templates = boolean()?,
            "allStepsFishCandidates" => {
                if value.len() != 9 || !value.bytes().all(|b| b == b'0' || b == b'1') {
                    return Err(InvalidInput);
                }
                self.all_digits = value
                    .bytes()
                    .enumerate()
                    .fold(0, |m, (i, b)| m | (u16::from(b == b'1') << i));
            }
            _ => return Err(InvalidInput),
        }
        Ok(())
    }
    pub(super) fn chain_limit(&self) -> usize {
        if self.restrict_chain {
            self.chain_length
        } else {
            161
        }
    }
}

/// Coarse, allocation-free admission before Java's ordinary result deduplication.
/// The Swift matcher verifies exact premise membership and roles on the snapshot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FineScope {
    Cells(u128),
    Digits(u16),
}
impl FineScope {
    fn parse(value: &str, digits: bool) -> Result<Self, InvalidInput> {
        let mut bits = 0u128;
        for part in value.split(',') {
            let n = part.parse::<usize>().map_err(|_| InvalidInput)?;
            if if digits {
                !(1..=9).contains(&n)
            } else {
                n >= 81
            } {
                return Err(InvalidInput);
            }
            bits |= 1u128 << n;
        }
        Ok(if digits {
            Self::Digits(bits as u16)
        } else {
            Self::Cells(bits)
        })
    }
    pub fn might_match(&self, step: &super::Step) -> bool {
        match *self {
            Self::Digits(digits) => {
                let values = step.values.iter().fold(0u16, |m, &d| m | (1 << d));
                values & digits == digits
            }
            Self::Cells(wanted) => {
                let mut bits = 0u128;
                for &c in &step.indices {
                    bits |= 1u128 << c;
                }
                for &(c, _) in step.fins.iter().chain(&step.endo_fins) {
                    bits |= 1u128 << c;
                }
                for &(c, _) in &step.colors {
                    bits |= 1u128 << c;
                }
                for (cs, _) in &step.alses {
                    for c in cs {
                        bits |= 1u128 << c;
                    }
                }
                for chain in &step.chains {
                    for &node in chain {
                        if node == i32::MIN {
                            continue;
                        }
                        let e = node.unsigned_abs();
                        let kind = (e >> 26) & 3;
                        if kind > 1 {
                            continue;
                        }
                        for &offset in if kind == 1 {
                            &[5, 12, 19][..]
                        } else {
                            &[5][..]
                        } {
                            let cell = (e >> offset) & 127;
                            if cell < 81 {
                                bits |= 1u128 << cell;
                            }
                        }
                    }
                }
                bits & wanted == wanted
            }
        }
    }
}
