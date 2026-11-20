// SPDX-License-Identifier: GPL-3.0-or-later
use std::{ffi::c_void, panic::catch_unwind, slice};

#[repr(C)]
pub struct ResultBuffer {
    status: u8,
    placement_cell: u8,
    placement_digit: u8,
    deletions: [u16; 81],
}

type Proof = extern "C" fn(*mut c_void, u16, *const usize, usize);

#[repr(C)]
pub struct ConclusionBuffer {
    truths: [u16; 81],
    falses: [u16; 81],
}

#[no_mangle]
pub unsafe extern "C" fn hodoku_analyze_chain_v1(
    values: *const u8,
    value_count: usize,
    masks: *const u16,
    mask_count: usize,
    atoms: *const u16,
    atom_count: usize,
    offsets: *const usize,
    offset_count: usize,
    edges: *const u8,
    edge_count: usize,
    closed: u8,
    proof: Option<Proof>,
    context: *mut c_void,
    out: *mut ResultBuffer,
) -> i32 {
    hodoku_analyze_chain_v2(
        values,
        value_count,
        masks,
        mask_count,
        atoms,
        atom_count,
        offsets,
        offset_count,
        edges,
        edge_count,
        closed,
        proof,
        context,
        out,
        std::ptr::null_mut(),
    )
}

#[no_mangle]
pub unsafe extern "C" fn hodoku_analyze_chain_v2(
    values: *const u8,
    value_count: usize,
    masks: *const u16,
    mask_count: usize,
    atoms: *const u16,
    atom_count: usize,
    offsets: *const usize,
    offset_count: usize,
    edges: *const u8,
    edge_count: usize,
    closed: u8,
    proof: Option<Proof>,
    context: *mut c_void,
    out: *mut ResultBuffer,
    batch: *mut ConclusionBuffer,
) -> i32 {
    if value_count != 81
        || mask_count != 81
        || values.is_null()
        || masks.is_null()
        || offsets.is_null()
        || offset_count == 0
        || offset_count > isize::MAX as usize / size_of::<usize>()
        || atoms.is_null() && atom_count != 0
        || edges.is_null() && edge_count != 0
        || atom_count > isize::MAX as usize / 2
        || edge_count > isize::MAX as usize
        || closed > 1
        || out.is_null()
    {
        return 1;
    }
    catch_unwind(|| {
        let values = &*values.cast::<[u8; 81]>();
        let masks = &*masks.cast::<[u16; 81]>();
        let atoms = if atom_count == 0 {
            &[]
        } else {
            slice::from_raw_parts(atoms, atom_count)
        };
        let edges = if edge_count == 0 {
            &[]
        } else {
            slice::from_raw_parts(edges, edge_count)
        };
        let offsets = slice::from_raw_parts(offsets, offset_count);
        if offsets.first() != Some(&0)
            || offsets.last() != Some(&atom_count)
            || offsets.windows(2).any(|w| w[0] >= w[1])
            || edges.iter().any(|&e| e > 1)
        {
            return 1;
        }
        let nodes: Vec<_> = offsets.windows(2).map(|w| &atoms[w[0]..w[1]]).collect();
        let result = match crate::chain::evaluate_selected(
            values,
            masks,
            &nodes,
            edges,
            closed != 0,
            !batch.is_null(),
        ) {
            Ok(value) => value,
            Err(_) => return 1,
        };
        let mut output = ResultBuffer {
            status: result.status,
            placement_cell: 255,
            placement_digit: 0,
            deletions: [0; 81],
        };
        if let Some(atom) = result.placement {
            output.placement_cell = (atom / 10) as u8;
            output.placement_digit = (atom % 10) as u8;
        }
        for (atom, literals) in result.proofs {
            if result.placement.is_none() {
                output.deletions[usize::from(atom / 10)] |= 1 << (atom % 10 - 1);
            }
            if let Some(callback) = proof {
                callback(context, atom, literals.as_ptr(), literals.len());
            }
        }
        if !batch.is_null() {
            let mut all = ConclusionBuffer {
                truths: [0; 81],
                falses: [0; 81],
            };
            for atom in result.truths {
                all.truths[usize::from(atom / 10)] |= 1 << (atom % 10 - 1);
            }
            for atom in result.falses {
                all.falses[usize::from(atom / 10)] |= 1 << (atom % 10 - 1);
            }
            batch.write(all);
        }
        out.write(output);
        0
    })
    .unwrap_or(2)
}
