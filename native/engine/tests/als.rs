// SPDX-License-Identifier: GPL-3.0-or-later
use hodoku_engine::phase5::als;

#[test]
fn death_blossom_petals_do_not_form_an_ordered_chain() {
    // Frozen Java regression library line 1464 (verification/als/library-samples.txt).
    #[rustfmt::skip]
    let masks = [
          0,   0,  0,   0,   6, 258, 0, 272,  20,
          0,   0,  0,  33, 292, 257, 0, 384, 132,
          0,   0,  0,   0,   0,   0, 0,   0,   0,
          9,   0,  0, 272,   0,  24, 0,  33, 288,
         73, 272, 24,   0, 392,   0, 0, 129, 192,
         96, 288,  0,   0,   0, 384, 0,   0, 448,
         42,   0, 24,   0, 130, 146, 0,   0,  48,
          0,  48,  0,  33,  40,  25, 0,   0,   0,
         34,   0,  0, 272, 290,   0, 0,  48,   0,
    ];
    let steps = als::catalogue(&masks, "DEATH_BLOSSOM", false, false, true, 6, &|| false);
    assert_eq!(steps.len(), 3);
    for (step, first_petal) in steps.iter().zip([&[14][..], &[5, 14], &[4, 5, 14]]) {
        assert_eq!(step.indices, [68]);
        assert_eq!(step.deletes, [(50, 9)]);
        assert_eq!(step.alses[0].0, first_petal);
        assert_eq!(step.restricted.len(), 3);
        assert!(step.chains.is_empty());
    }
}
