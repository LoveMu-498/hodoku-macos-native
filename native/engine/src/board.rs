// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Sudoku2/SudokuSinglesQueue, Copyright (C) 2008-12 Bernhard Hobiger.
use std::collections::VecDeque;

const ALL: u16 = 0x1ff;
fn bit(digit: u8) -> u16 {
    1 << (digit - 1)
}
pub(crate) fn digits(mask: u16) -> impl Iterator<Item = u8> {
    let mut bits = mask;
    std::iter::from_fn(move || {
        if bits == 0 {
            return None;
        }
        let digit = bits.trailing_zeros() as u8 + 1;
        bits &= bits - 1;
        Some(digit)
    })
}
pub(crate) const fn houses(cell: usize) -> [usize; 3] {
    [cell / 9, 9 + cell % 9, 18 + cell / 27 * 3 + cell % 9 / 3]
}
const fn peers() -> [[usize; 20]; 81] {
    let mut table = [[0; 20]; 81];
    let mut i = 0;
    while i < 81 {
        let mut j = 0;
        let mut n = 0;
        while j < 81 {
            let a = houses(i);
            let b = houses(j);
            if i != j && (a[0] == b[0] || a[1] == b[1] || a[2] == b[2]) {
                table[i][n] = j;
                n += 1;
            }
            j += 1;
        }
        i += 1;
    }
    table
}
static PEERS: [[usize; 20]; 81] = peers();

#[derive(Clone, Default)]
pub(crate) struct Singles {
    pub(crate) naked: VecDeque<(usize, u8)>,
    pub(crate) hidden: VecDeque<(usize, u8)>,
}

#[derive(Clone)]
pub struct Board {
    pub values: [u8; 81],
    pub masks: [u16; 81],
    free: [[i16; 9]; 27],
    pub remaining: usize,
}

impl Board {
    pub(crate) fn empty() -> Self {
        Self {
            values: [0; 81],
            masks: [ALL; 81],
            free: [[9; 9]; 27],
            remaining: 81,
        }
    }

    pub(crate) fn from_snapshot(
        values: &[u8; 81],
        masks: Option<&[u16; 81]>,
    ) -> Result<(Self, Singles), super::InvalidInput> {
        let mut board = Self::empty();
        let mut pending = Singles::default();
        for (cell, &digit) in values.iter().enumerate() {
            if digit == 0 {
                continue;
            }
            if digit > 9 || PEERS[cell].iter().any(|&peer| board.values[peer] == digit) {
                return Err(super::InvalidInput);
            }
            board.place(cell, digit, &mut pending);
        }
        if let Some(actual) = masks {
            for (cell, &mask) in actual.iter().enumerate() {
                if mask & !board.masks[cell] != 0 {
                    return Err(super::InvalidInput);
                }
            }
            pending = board.rebuild(actual);
        }
        Ok((board, pending))
    }

    /// Sudoku2.rebuildInternalData resets the singles FIFOs in a different order
    /// than inserting all givens into a fresh Sudoku2.
    pub(crate) fn rebuild(&mut self, actual: &[u16; 81]) -> Singles {
        self.masks = *actual;
        self.remaining = self.values.iter().filter(|&&v| v == 0).count();
        self.free = [[0; 9]; 27];
        let mut pending = Singles::default();
        for (cell, &mask) in actual.iter().enumerate() {
            if mask.count_ones() == 1 {
                pending
                    .naked
                    .push_back((cell, mask.trailing_zeros() as u8 + 1));
            }
            for digit in digits(mask) {
                for house in houses(cell) {
                    self.free[house][digit as usize - 1] += 1;
                }
            }
        }
        for house in 0..27 {
            for digit in 1..=9 {
                if self.free[house][digit as usize - 1] == 1 {
                    self.enqueue_hidden(house, digit, &mut pending);
                }
            }
        }
        pending
    }

    fn enqueue_hidden(&self, house: usize, digit: u8, pending: &mut Singles) {
        for offset in 0..9 {
            let cell = match house {
                0..=8 => 9 * house + offset,
                9..=17 => 9 * offset + house - 9,
                _ => (house - 18) / 3 * 27 + (house - 18) % 3 * 3 + offset / 3 * 9 + offset % 3,
            };
            if self.masks[cell] & bit(digit) != 0 {
                pending.hidden.push_back((cell, digit));
                return;
            }
        }
    }

    pub(crate) fn free_in_house(&self, house: usize, digit: u8) -> i16 {
        self.free[house][digit as usize - 1]
    }

    pub(crate) fn delete(&mut self, cell: usize, value: u8, pending: &mut Singles) -> bool {
        if self.masks[cell] & bit(value) == 0 {
            return true;
        }
        self.masks[cell] &= !bit(value);
        let mask = self.masks[cell];
        if mask == 0 {
            return false;
        }
        if mask.count_ones() == 1 {
            pending
                .naked
                .push_back((cell, mask.trailing_zeros() as u8 + 1));
        }
        for house in houses(cell) {
            let free = &mut self.free[house][value as usize - 1];
            *free -= 1;
            match *free {
                1 => self.enqueue_hidden(house, value, pending),
                0 => {
                    if let Some(index) = pending
                        .hidden
                        .iter()
                        .position(|&(i, d)| d == value && houses(i).contains(&house))
                    {
                        pending.hidden.remove(index);
                    }
                }
                _ => {}
            }
        }
        true
    }

    pub(crate) fn place(&mut self, cell: usize, value: u8, pending: &mut Singles) -> bool {
        let prior = self.masks[cell];
        self.masks[cell] = 0;
        self.values[cell] = value;
        self.remaining -= 1;
        let mut valid = true;
        for &peer in &PEERS[cell] {
            if !self.delete(peer, value, pending) {
                valid = false;
            }
        }
        for digit in digits(prior) {
            for house in houses(cell) {
                let free = &mut self.free[house][digit as usize - 1];
                *free -= 1;
                if digit == value {
                    continue;
                }
                match *free {
                    1 => self.enqueue_hidden(house, digit, pending),
                    0 => valid = false,
                    _ => {}
                }
            }
        }
        valid
    }

    pub(crate) fn propagate(&mut self, pending: &mut Singles) -> bool {
        while !pending.naked.is_empty() || !pending.hidden.is_empty() {
            // Finish each FIFO before switching, including singles generated during that pass.
            for hidden in [false, true] {
                loop {
                    let next = if hidden {
                        pending.hidden.pop_front()
                    } else {
                        pending.naked.pop_front()
                    };
                    let Some((cell, digit)) = next else {
                        break;
                    };
                    if self.masks[cell] & bit(digit) != 0 && !self.place(cell, digit, pending) {
                        return false;
                    }
                }
            }
        }
        true
    }
}
