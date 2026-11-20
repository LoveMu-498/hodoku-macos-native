// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from HoDoKu's solvers, Copyright (C) 2008-12 Bernhard Hobiger.
use super::Step;
use std::ops::ControlFlow;
mod catalogue;
use crate::board::{digits, houses};
mod chains;
mod colors;
pub(crate) mod fish;
mod options;
mod patterns;
pub use options::{FineScope, Options};

const fn house_sets() -> [u128; 27] {
    let mut result = [0; 27];
    let mut i = 0;
    while i < 81 {
        let h = houses(i);
        result[h[0]] |= 1u128 << i;
        result[h[1]] |= 1u128 << i;
        result[h[2]] |= 1u128 << i;
        i += 1;
    }
    result
}
pub(super) const UNITS: [u128; 27] = house_sets();
const fn peer_sets() -> [u128; 81] {
    let mut result = [0; 81];
    let mut i = 0;
    while i < 81 {
        let h = houses(i);
        result[i] = (UNITS[h[0]] | UNITS[h[1]] | UNITS[h[2]]) & !(1u128 << i);
        i += 1;
    }
    result
}
pub(super) const PEERS: [u128; 81] = peer_sets();
const ALL: u128 = (1u128 << 81) - 1;
pub(super) fn cells(mut bits: u128) -> impl Iterator<Item = u8> {
    std::iter::from_fn(move || {
        if bits == 0 {
            return None;
        }
        let i = bits.trailing_zeros() as u8;
        bits &= bits - 1;
        Some(i)
    })
}
fn candidates(set: u128, d: u8) -> Vec<(u8, u8)> {
    cells(set).map(|c| (c, d)).collect()
}
pub(super) fn digit_sets(masks: &[u16; 81]) -> [u128; 10] {
    let mut result = [0u128; 10];
    for (cell, &mask) in masks.iter().enumerate() {
        for d in digits(mask) {
            result[d as usize] |= 1u128 << cell;
        }
    }
    result
}
fn sees(a: u8, b: u8) -> bool {
    PEERS[a as usize] & (1u128 << b) != 0
}
fn pair(set: u128) -> Option<[u8; 2]> {
    if set.count_ones() != 2 {
        return None;
    }
    Some([
        set.trailing_zeros() as u8,
        (127 - set.leading_zeros()) as u8,
    ])
}
pub fn supports(technique: &str) -> bool {
    fish::spec(technique).is_some()
        || matches!(
            technique,
            "XY_WING"
                | "XYZ_WING"
                | "W_WING"
                | "SKYSCRAPER"
                | "TWO_STRING_KITE"
                | "EMPTY_RECTANGLE"
                | "BUG_PLUS_1"
                | "REMOTE_PAIR"
                | "TURBOT_FISH"
                | "XY_CHAIN"
                | "X_CHAIN"
                | "SIMPLE_COLORS"
                | "SIMPLE_COLORS_WRAP"
                | "SIMPLE_COLORS_TRAP"
                | "MULTI_COLORS"
                | "MULTI_COLORS_1"
                | "MULTI_COLORS_2"
        )
}
pub fn first(values: &[u8; 81], masks: &[u16; 81], technique: &str) -> Option<Step> {
    first_cancellable(values, masks, technique, &|| false)
}
pub fn first_cancellable(
    values: &[u8; 81],
    masks: &[u16; 81],
    technique: &str,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    first_with_options(values, masks, technique, &Options::default(), cancelled)
}
pub fn first_with_options(
    values: &[u8; 81],
    masks: &[u16; 81],
    technique: &str,
    options: &Options,
    cancelled: &dyn Fn() -> bool,
) -> Option<Step> {
    if !supports(technique) {
        return None;
    }
    let sets = digit_sets(masks);
    if options.duals && matches!(technique, "TWO_STRING_KITE" | "EMPTY_RECTANGLE") {
        return catalogue::pattern_list(masks, &sets, technique, options, cancelled)
            .into_iter()
            .next();
    }
    match technique {
        "XY_WING" | "XYZ_WING" | "W_WING" | "SKYSCRAPER" | "TWO_STRING_KITE"
        | "EMPTY_RECTANGLE" | "SIMPLE_COLORS" | "SIMPLE_COLORS_WRAP" | "SIMPLE_COLORS_TRAP"
        | "MULTI_COLORS" | "MULTI_COLORS_1" | "MULTI_COLORS_2" => {
            patterns(masks, &sets, technique, options, &mut ControlFlow::Break).break_value()
        }
        "REMOTE_PAIR" => chains::search(
            masks,
            &sets,
            "REMOTE_PAIR",
            cancelled,
            false,
            options.chain_limit(),
            None,
        )
        .into_iter()
        .next(),
        "TURBOT_FISH" => chains::search(
            masks,
            &sets,
            "TURBOT_FISH",
            cancelled,
            false,
            options.chain_limit(),
            None,
        )
        .into_iter()
        .next(),
        "X_CHAIN" => chains::search(
            masks,
            &sets,
            "X_CHAIN",
            cancelled,
            false,
            options.chain_limit(),
            None,
        )
        .into_iter()
        .next(),
        "XY_CHAIN" => chains::search(
            masks,
            &sets,
            "XY_CHAIN",
            cancelled,
            false,
            options.chain_limit(),
            None,
        )
        .into_iter()
        .next(),
        "BUG_PLUS_1" => patterns::bug(masks, &sets),
        _ => fish::search(values, &sets, fish::spec(technique)?, options, cancelled),
    }
}

fn patterns(
    masks: &[u16; 81],
    sets: &[u128; 10],
    technique: &str,
    options: &Options,
    emit: &mut dyn FnMut(Step) -> ControlFlow<Step>,
) -> ControlFlow<Step> {
    match technique {
        "XY_WING" | "XYZ_WING" => patterns::wing(masks, sets, technique == "XYZ_WING", emit),
        "W_WING" => patterns::w_wing(masks, sets, emit),
        "SKYSCRAPER" => patterns::skyscraper(sets, emit),
        "DUAL_TWO_STRING_KITE" | "TWO_STRING_KITE" => patterns::kite(sets, emit),
        "DUAL_EMPTY_RECTANGLE" | "EMPTY_RECTANGLE" => {
            patterns::rectangle(sets, options.two_candidate_rectangles, emit)
        }
        "SIMPLE_COLORS" | "SIMPLE_COLORS_WRAP" | "SIMPLE_COLORS_TRAP" => {
            colors::search(sets, false, emit)
        }
        "MULTI_COLORS" | "MULTI_COLORS_1" | "MULTI_COLORS_2" => colors::search(sets, true, emit),
        _ => ControlFlow::Continue(()),
    }
}

pub use catalogue::{catalogue, catalogue_with_options};
