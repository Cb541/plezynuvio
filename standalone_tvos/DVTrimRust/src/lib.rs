//! Experimental per-frame RPU trim. Never modifies decoded pixels.
//! No-op on parse errors and on metadata without existing L2/L8 trims.
//! Saturation/contrast/brightness are exploratory, not calibrated controls.
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::rpu::extension_metadata::{DmData, WithExtMetadataBlocks};
use dolby_vision::rpu::extension_metadata::blocks::ExtMetadataBlock;
use std::slice;

fn offset12(base: u16, factor: f32, strength: f32) -> u16 {
    let delta = (factor.clamp(0.7, 1.5) - 1.0) * strength;
    (f32::from(base) + delta).round().clamp(0.0, 4095.0) as u16
}

/// Attempts an adjustment of already-present Level 2/8 trims. Caller owns
/// input and output memory. Returns 0 if parsing, validation or data capacity
/// fails, so the untouched input is passed through the native renderer.
/// status: 1 edited, -1 invalid input, -2 no editable trim blocks.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nuvio_dv_adjust_rpu(
    input: *const u8, input_len: usize, output: *mut u8, output_cap: usize,
    saturation: f32, contrast: f32, brightness: f32, status: *mut i32
) -> usize {
    if !status.is_null() { unsafe { *status = -1; } }
    if input.is_null() || output.is_null() || input_len < 8
        || input_len > 4096 || output_cap < input_len
        || !saturation.is_finite() || !contrast.is_finite() || !brightness.is_finite()
    { return 0; }
    let data = unsafe { slice::from_raw_parts(input, input_len) };
    let parsed = DoviRpu::parse_rpu(data)
        .map(|r| (r, false))
        .or_else(|_| DoviRpu::parse_unspec62_nalu(data).map(|r| (r, true)));
    let (mut rpu, has_nal) = match parsed { Ok(v) => v, Err(_) => return 0 };
    let mut edits = 0_usize;
    if let Some(dm) = rpu.vdr_dm_data.as_mut() {
        if let Some(DmData::V29(ref mut v29)) = dm.cmv29_metadata {
            for block in v29.blocks_mut() {
                if let ExtMetadataBlock::Level2(level) = block {
                    level.trim_saturation_gain = offset12(level.trim_saturation_gain, saturation, 500.0);
                    level.trim_slope = offset12(level.trim_slope, contrast, 260.0);
                    level.trim_offset = offset12(level.trim_offset, brightness, 310.0);
                    edits += 1;
                }
            }
        }
        if let Some(DmData::V40(ref mut v40)) = dm.cmv40_metadata {
            for block in v40.blocks_mut() {
                if let ExtMetadataBlock::Level8(level) = block {
                    level.trim_saturation_gain = offset12(level.trim_saturation_gain, saturation, 500.0);
                    level.trim_slope = offset12(level.trim_slope, contrast, 260.0);
                    level.trim_offset = offset12(level.trim_offset, brightness, 310.0);
                    edits += 1;
                }
            }
        }
    }
    if edits == 0 {
        if !status.is_null() { unsafe { *status = -2; } }
        return 0;
    }
    rpu.modified = true;
    let serialized = if has_nal { rpu.write_hevc_unspec62_nalu() } else { rpu.write_rpu() };
    let bytes = match serialized { Ok(b) => b, Err(_) => return 0 };
    if bytes.len() > output_cap || bytes.is_empty() { return 0; }
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len()); }
    if !status.is_null() { unsafe { *status = 1; } }
    bytes.len()
}
