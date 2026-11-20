// SPDX-License-Identifier: GPL-3.0-or-later
use crate::count_solutions;
use std::{
    panic::catch_unwind,
    sync::atomic::{AtomicBool, Ordering},
};

pub struct HodokuCancellation(AtomicBool);

#[repr(C)]
pub struct HodokuCountResult {
    termination: u32,
    count: u32,
    tries: u32,
    solution: [u8; 81],
}

#[no_mangle]
pub extern "C" fn hodoku_engine_abi_version() -> u32 {
    1
}

#[no_mangle]
pub extern "C" fn hodoku_cancellation_new() -> *mut HodokuCancellation {
    Box::into_raw(Box::new(HodokuCancellation(AtomicBool::new(false))))
}

#[no_mangle]
pub unsafe extern "C" fn hodoku_cancellation_request(token: *mut HodokuCancellation) {
    // SAFETY: the caller holds a live token or NULL and will not free it during request.
    if let Some(token) = unsafe { token.as_ref() } {
        token.0.store(true, Ordering::Relaxed);
    }
}

#[no_mangle]
pub unsafe extern "C" fn hodoku_cancellation_free(token: *mut HodokuCancellation) {
    if !token.is_null() {
        // SAFETY: caller owns this allocation from new and has joined every user.
        drop(unsafe { Box::from_raw(token) });
    }
}

#[no_mangle]
pub unsafe extern "C" fn hodoku_count_solutions_v1(
    values: *const u8,
    value_count: usize,
    candidates: *const u16,
    candidate_count: usize,
    max_solutions: i32,
    max_tries: i32,
    cancel: *const HodokuCancellation,
    out: *mut HodokuCountResult,
) -> i32 {
    if values.is_null()
        || value_count != 81
        || out.is_null()
        || !matches!(
            (candidates.is_null(), candidate_count),
            (true, 0) | (false, 81)
        )
        || max_solutions < 0
        || max_tries < 0
    {
        return 1;
    }
    catch_unwind(|| {
        // SAFETY: checked lengths and nullability above. The C contract requires
        // aligned, live, disjoint buffers until return, including the optional token.
        let (values, masks, token) = unsafe {
            (
                &*values.cast::<[u8; 81]>(),
                candidates.cast::<[u16; 81]>().as_ref(),
                cancel.as_ref(),
            )
        };
        let result = count_solutions(
            values,
            masks,
            max_solutions as u32,
            max_tries as u32,
            &|| token.is_some_and(|t| t.0.load(Ordering::Relaxed)),
        );
        match result {
            Err(_) => 1,
            Ok(r) => {
                // SAFETY: caller supplied writable storage for one repr(C) result.
                unsafe {
                    out.write(HodokuCountResult {
                        termination: r.termination as u32,
                        count: r.count,
                        tries: r.tries,
                        solution: r.solution.unwrap_or([0; 81]),
                    })
                };
                0
            }
        }
    })
    .unwrap_or(2)
}

#[no_mangle]
pub unsafe extern "C" fn hodoku_next_step_v1(
    values: *const u8,
    value_count: usize,
    candidates: *const u16,
    candidate_count: usize,
    out: *mut crate::hints::HintStep,
) -> i32 {
    // SAFETY: callers provide the buffers and lifetimes documented by the C API.
    unsafe { hint_result(values, value_count, candidates, candidate_count, out, None) }
}

#[no_mangle]
pub unsafe extern "C" fn hodoku_step_for_cells_v1(
    values: *const u8,
    value_count: usize,
    candidates: *const u16,
    candidate_count: usize,
    selected_cells: *const u8,
    selected_count: usize,
    out: *mut crate::hints::HintStep,
) -> i32 {
    if selected_cells.is_null() || !(1..=81).contains(&selected_count) {
        return 1;
    }
    // SAFETY: the non-null selection and remaining buffers are live for this call.
    unsafe {
        let selected = std::slice::from_raw_parts(selected_cells, selected_count);
        hint_result(
            values,
            value_count,
            candidates,
            candidate_count,
            out,
            Some(selected),
        )
    }
}

unsafe fn hint_result(
    values: *const u8,
    value_count: usize,
    candidates: *const u16,
    candidate_count: usize,
    out: *mut crate::hints::HintStep,
    selected: Option<&[u8]>,
) -> i32 {
    if values.is_null()
        || candidates.is_null()
        || out.is_null()
        || value_count != 81
        || candidate_count != 81
    {
        return 1;
    }
    catch_unwind(|| {
        // SAFETY: checked lengths and nullability. The C contract requires live,
        // aligned disjoint arrays, and writable out storage until the call returns.
        let (values, masks) = unsafe {
            (
                &*values.cast::<[u8; 81]>(),
                &*candidates.cast::<[u16; 81]>(),
            )
        };
        let step = match selected {
            Some(cells) => crate::hints::step_for_cells(values, masks, cells),
            None => crate::hints::next_step(values, masks),
        };
        match step {
            Ok(step) => {
                // SAFETY: the caller supplied writable storage for the repr(C) step.
                unsafe { out.write(step) };
                0
            }
            Err(_) => 1,
        }
    })
    .unwrap_or(2)
}

#[no_mangle]
pub unsafe extern "C" fn hodoku_hint_catalog_v1(
    values: *const u8,
    value_count: usize,
    candidates: *const u16,
    candidate_count: usize,
    callback: Option<extern "C" fn(*mut std::ffi::c_void, *const crate::hints::HintStep)>,
    context: *mut std::ffi::c_void,
) -> i32 {
    let Some(visit) = callback else { return 1 };
    if values.is_null() || candidates.is_null() || value_count != 81 || candidate_count != 81 {
        return 1;
    }
    catch_unwind(|| {
        // SAFETY: both checked buffers are aligned and live per the C contract.
        let (values, masks) = unsafe {
            (
                &*values.cast::<[u8; 81]>(),
                &*candidates.cast::<[u16; 81]>(),
            )
        };
        match crate::hints::catalogue(values, masks) {
            Ok(list) => {
                for step in &list {
                    visit(context, step)
                }
                0
            }
            Err(_) => 1,
        }
    })
    .unwrap_or(2)
}
