//! Conservative Dolby Vision RPU experiment, intentionally saturation-only.
//! The previous iteration changed L2 and L8 trims for *all* target displays
//! and introduced large, uncalibrated offset/slope changes. That was unsafe.
//! This version requires a byte-exact metadata round trip and modifies at
//! most one existing saturation trim, leaving tone mapping fully untouched.
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::rpu::extension_metadata::{DmData, WithExtMetadataBlocks};
use dolby_vision::rpu::extension_metadata::blocks::ExtMetadataBlock;
use std::slice;

fn is_valid_trim(value: u16) -> bool {
    // Skip unusually extreme authored values; 2048 encodes neutral.
    (1024..=3072).contains(&value)
}

fn adjust_saturation(base: u16, factor: f32) -> u16 {
    // At a 5% slider step, change the encoded metadata by only ~10 units
    // (about 0.5% of the centered 2048 range), not an uncalibrated 25+.
    let clamped = factor.clamp(0.90, 1.10);
    let change = (clamped - 1.0) * 2048.0 * 0.10;
    (f32::from(base) + change).round().clamp(0.0, 4095.0) as u16
}

fn to_bytes(rpu: &DoviRpu, has_nal: bool) -> anyhow::Result<Vec<u8>> {
    if has_nal { rpu.write_hevc_unspec62_nalu() } else { rpu.write_rpu() }
}

/// Returns 0 on any unsafe edit. status: 1 applied, -1 invalid,
/// -2 no suitable target, -3 non-identical round trip, -4 reparse failed.
/// Contrast and brightness are intentionally disabled pending safe validation.
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

    // Single-axis isolation: do not alter the tone curve or chroma weight.
    if (contrast - 1.0).abs() > 0.001 || (brightness - 1.0).abs() > 0.001 {
        return 0;
    }
    if (saturation - 1.0).abs() < 0.001 { return 0; }

    let data = unsafe { slice::from_raw_parts(input, input_len) };
    let parsed = DoviRpu::parse_rpu(data)
        .map(|r| (r, false))
        .or_else(|_| DoviRpu::parse_unspec62_nalu(data).map(|r| (r, true)));
    let (mut rpu, has_nal) = match parsed { Ok(v) => v, Err(_) => return 0 };

    // A valid parse alone isn't enough: ensure libdovi reproduces the exact
    // original bytes before allowing a metadata write. This also detects
    // unusual/unknown payload representations and already-modified blobs.
    match to_bytes(&rpu, has_nal) {
        Ok(bytes) if bytes == data => (),
        _ => {
            if !status.is_null() { unsafe { *status = -3; } }
            return 0;
        }
    }

    let mut changed = false;
    if let Some(dm) = rpu.vdr_dm_data.as_mut() {
        // Prefer exactly one 1000-nit CMv4.0 target (common HDR TV class).
        // Never edit all targets or both CM2.9 and CM4 at once.
        if let Some(DmData::V40(ref mut cm40)) = dm.cmv40_metadata {
            let blocks = cm40.blocks_mut();
            if let Some(level) = blocks.iter_mut().find_map(|block| {
                if let ExtMetadataBlock::Level8(level) = block {
                    if (level.trim_target_nits() == 1000 || level.trim_target_nits() == 600)
                        && is_valid_trim(level.trim_saturation_gain) {
                        return Some(level);
                    }
                }
                None
            }) {
                level.trim_saturation_gain = adjust_saturation(level.trim_saturation_gain, saturation);
                changed = true;
            }
        }

        // Older CM2.9 metadata: change a single existing target only when
        // the RPU has no suitable CM4 target.
        if !changed {
            if let Some(DmData::V29(ref mut cm29)) = dm.cmv29_metadata {
                for block in cm29.blocks_mut() {
                    if let ExtMetadataBlock::Level2(level) = block {
                        if is_valid_trim(level.trim_saturation_gain) {
                            level.trim_saturation_gain = adjust_saturation(level.trim_saturation_gain, saturation);
                            changed = true;
                            break;
                        }
                    }
                }
            }
        }
    }
    if !changed {
        if !status.is_null() { unsafe { *status = -2; } }
        return 0;
    }
    rpu.modified = true;
    let bytes = match to_bytes(&rpu, has_nal) { Ok(b) => b, Err(_) => return 0 };
    if bytes.len() > output_cap || bytes.is_empty() { return 0; }

    // Reparse the new blob, including its recalculated CRC, before replacing
    // the metadata attachment. On failure, the caller retains the original.
    let valid = if has_nal {
        DoviRpu::parse_unspec62_nalu(&bytes).is_ok()
    } else {
        DoviRpu::parse_rpu(&bytes).is_ok()
    };
    if !valid {
        if !status.is_null() { unsafe { *status = -4; } }
        return 0;
    }

    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len()); }
    if !status.is_null() { unsafe { *status = 1; } }
    bytes.len()
}
