//! Conservative Dolby Vision RPU experiment, intentionally saturation-only.
//! The previous iteration changed L2 and L8 trims for *all* target displays
//! and introduced large, uncalibrated offset/slope changes. That was unsafe.
//! This version requires a byte-exact metadata round trip and modifies
//! saturation *only*, consistently across the existing mapped display
//! targets, leaving tone mapping and color transforms fully untouched.
use dolby_vision::rpu::dovi_rpu::DoviRpu;
use dolby_vision::rpu::extension_metadata::{DmData, WithExtMetadataBlocks};
use dolby_vision::rpu::extension_metadata::blocks::ExtMetadataBlock;
use std::slice;

fn is_valid_trim(value: u16) -> bool {
    // Skip unusually extreme authored values; 2048 encodes neutral.
    (1024..=3072).contains(&value)
}

fn adjust_saturation(base: u16, factor: f32) -> u16 {
    // Dolby's nominal neutral is 2048 in 12-bit trim units. The earlier
    // 0.10 gain made a 5% UI step only ~10 units, effectively invisible.
    // Use the proportional range instead: 105% -> +102 units, 125% -> +512.
    // This remains saturation-only and does not touch tone-mapping controls.
    let clamped = factor.clamp(0.80, 1.25);
    let change = (clamped - 1.0) * 2048.0;
    (f32::from(base) + change).round().clamp(0.0, 4095.0) as u16
}

/// Apple may attach either the standalone RPU payload, an HEVC UNSPEC62
/// NALU (with emulation-prevention bytes), or a payload with a leading
/// Annex-B/short prefix. libdovi's parse_rpu() strips these wrappers, while
/// write_rpu() intentionally does NOT put them back. Comparing those two
/// representations caused spurious "not byte-exact" (-3) errors.
#[derive(Clone, Copy)]
enum RpuContainer { Payload { prefix: usize }, HevcNal }

fn container_for(data: &[u8]) -> Option<RpuContainer> {
    match data.get(..5)? {
        [0, 0, 0, 1, 25] => Some(RpuContainer::Payload { prefix: 4 }),
        [0, 0, 1, 25, 8] => Some(RpuContainer::Payload { prefix: 3 }),
        [0, 1, 25, 8, 9] => Some(RpuContainer::Payload { prefix: 2 }),
        [124, 1, 25, 8, 9] => Some(RpuContainer::HevcNal),
        [1, 25, 8, 9, _] => Some(RpuContainer::Payload { prefix: 1 }),
        [25, 8, 9, _, _] => Some(RpuContainer::Payload { prefix: 0 }),
        _ => None,
    }
}

fn parse_container(data: &[u8], kind: RpuContainer) -> anyhow::Result<DoviRpu> {
    match kind {
        RpuContainer::HevcNal => DoviRpu::parse_unspec62_nalu(data),
        RpuContainer::Payload { .. } => DoviRpu::parse_rpu(data),
    }
}

fn to_bytes(rpu: &DoviRpu, kind: RpuContainer, original: &[u8]) -> anyhow::Result<Vec<u8>> {
    match kind {
        RpuContainer::HevcNal => rpu.write_hevc_unspec62_nalu(),
        RpuContainer::Payload { prefix } => {
            let payload = rpu.write_rpu()?;
            let mut output = Vec::with_capacity(prefix + payload.len());
            output.extend_from_slice(&original[..prefix]);
            output.extend_from_slice(&payload);
            Ok(output)
        }
    }
}

/// Returns 0 on any unsafe edit. status: positive = number of existing
/// saturation trim targets edited, -1 invalid, -2 no suitable target,
/// -3 non-identical round trip (after preserving the original wrapper),
/// -4 edited reparse failed, -5 RPU parse failed, -6 trim values out of range,
/// -7 no DM metadata, -8 serialization failed, -9 unsupported RPU wrapper.
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
    let kind = match container_for(data) {
        Some(k) => k,
        None => {
            if !status.is_null() { unsafe { *status = -9; } }
            return 0;
        }
    };
    let mut rpu = match parse_container(data, kind) {
        Ok(r) => r,
        Err(_) => {
            if !status.is_null() { unsafe { *status = -5; } }
            return 0;
        }
    };

    // A valid parse alone isn't enough: ensure libdovi reproduces the exact
    // original bytes before allowing a metadata write. This also detects
    // unusual/unknown payload representations and already-modified blobs.
    match to_bytes(&rpu, kind, data) {
        Ok(bytes) if bytes == data => (),
        _ => {
            if !status.is_null() { unsafe { *status = -3; } }
            return 0;
        }
    }

    // All *existing* targets receive the same saturation gain change.
    // A TV can select a different target based on the display's luminance,
    // so editing a single 600/1000-nit block often has no visible effect.
    // Crucially, no new target blocks are invented, no L1/3 mapping metadata
    // is modified, and CMv2.9 isn't edited when CMv4.0 has been changed.
    let mut edited_targets: i32 = 0;
    let mut candidate_targets: i32 = 0;
    let mut eligible_targets: i32 = 0;
    if let Some(dm) = rpu.vdr_dm_data.as_mut() {
        if let Some(DmData::V40(ref mut cm40)) = dm.cmv40_metadata {
            for block in cm40.blocks_mut() {
                if let ExtMetadataBlock::Level8(level) = block {
                    candidate_targets += 1;
                    if is_valid_trim(level.trim_saturation_gain) {
                        eligible_targets += 1;
                        let original = level.trim_saturation_gain;
                        let adjusted = adjust_saturation(original, saturation);
                        if original != adjusted {
                            level.trim_saturation_gain = adjusted;
                            edited_targets += 1;
                        }
                    }
                }
            }
        }
        if edited_targets == 0 {
            if let Some(DmData::V29(ref mut cm29)) = dm.cmv29_metadata {
                for block in cm29.blocks_mut() {
                    if let ExtMetadataBlock::Level2(level) = block {
                        candidate_targets += 1;
                        if is_valid_trim(level.trim_saturation_gain) {
                            eligible_targets += 1;
                            let original = level.trim_saturation_gain;
                            let adjusted = adjust_saturation(original, saturation);
                            if original != adjusted {
                                level.trim_saturation_gain = adjusted;
                                edited_targets += 1;
                            }
                        }
                    }
                }
            }
        }
    }
    if edited_targets == 0 {
        let diagnostic = if rpu.vdr_dm_data.is_none() { -7 }
            else if candidate_targets == 0 { -2 }
            else if eligible_targets == 0 { -6 }
            else { -1 };
        if !status.is_null() { unsafe { *status = diagnostic; } }
        return 0;
    }
    rpu.modified = true;
    let bytes = match to_bytes(&rpu, kind, data) {
        Ok(b) => b,
        Err(_) => {
            if !status.is_null() { unsafe { *status = -8; } }
            return 0;
        }
    };
    if bytes.len() > output_cap || bytes.is_empty() {
        if !status.is_null() { unsafe { *status = -8; } }
        return 0;
    }

    // Reparse the new blob, including its recalculated CRC, before replacing
    // the metadata attachment. On failure, the caller retains the original.
    let valid = parse_container(&bytes, kind).is_ok();
    if !valid {
        if !status.is_null() { unsafe { *status = -4; } }
        return 0;
    }

    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len()); }
    if !status.is_null() { unsafe { *status = edited_targets; } }
    bytes.len()
}
