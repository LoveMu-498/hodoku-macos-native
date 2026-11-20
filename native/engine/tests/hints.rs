// SPDX-License-Identifier: GPL-3.0-or-later
use hodoku_engine::hints::{next_step, step_for_cells, Technique};

#[test]
fn reports_local_conflicts_and_distinguishes_an_unsupported_position() {
    let board = [0; 81];
    let mut masks = [511; 81];
    assert_eq!(
        next_step(&board, &masks).unwrap().technique,
        Technique::None
    );
    masks[..9].fill(510);
    assert!(next_step(&board, &masks).is_err());
    masks[0] = 512;
    assert!(step_for_cells(&board, &masks, &[0]).is_err());
}

#[test]
fn selection_finds_later_instances_and_rejects_duplicate_ids() {
    let board = [0; 81];
    let mut masks = [511; 81];
    masks[0] = 1;
    masks[80] = 2;
    assert_eq!(next_step(&board, &masks).unwrap().placement_cell, 0);
    assert_eq!(
        step_for_cells(&board, &masks, &[80])
            .unwrap()
            .placement_cell,
        80
    );
    assert_eq!(
        step_for_cells(&board, &masks, &[80, 0]).unwrap().technique,
        Technique::None
    );
    assert!(step_for_cells(&board, &masks, &[80, 80]).is_err());
}

#[test]
fn selected_pointing_uses_catalogue_order_ordinary_uses_stepfinder_order() {
    let board = [0; 81];
    let mut masks = [511; 81];
    for c in [2, 9, 10, 11, 18, 19, 20] {
        masks[c] = 508;
    }
    masks[3] = 510;
    masks[8] = 509;
    let ordinary = next_step(&board, &masks).unwrap();
    let selected = step_for_cells(&board, &masks, &[1, 0]).unwrap();
    assert_eq!(
        (ordinary.technique, ordinary.digits),
        (Technique::Pointing, 1)
    );
    assert_eq!(
        (selected.technique, selected.digits),
        (Technique::Pointing, 2)
    );
    assert_eq!(&selected.deletions[2..9], &[0, 2, 2, 2, 2, 2, 0]);
}
