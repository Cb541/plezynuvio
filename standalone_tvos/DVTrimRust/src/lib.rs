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

/// Apple's Core Video attachment can contain a raw RPU, a prefixed RPU,
/// or the same payload with HEVC emulation-prevention bytes. A plain
/// parse_rpu() does not remove EPB (00 00 03), whereas parse_unspec62_nalu()
/// does. Both forms may start with 0x19 after their optional wrapper.
///
/// Earlier v5 assumed EPB only for 7C01 NAL headers, rejecting perfectly
/// valid prefixed RPU blobs with code -5. Do NOT select a parser based solely
/// on the prefix: select it by successfully parsing AND reproducing the exact
/// original wrapper and bytes. Never drop the CRC round-trip guard.
#[derive(Clone, Copy)]
enum RpuEncoding { Raw, EmulationPrevented }

#[derive(Clone, Copy)]
struct RpuContainer {
    prefix: usize,
    nal_header: bool,
    encoding: RpuEncoding,
}

fn identify_wrapper(data: &[u8]) -> Option<(usize, bool)> {
    if data.starts_with(&[0, 0, 0, 1, 124, 1, 25]) { return Some((4, true)); }
    if data.starts_with(&[0, 0, 1, 124, 1, 25]) { return Some((3, true)); }
    if data.starts_with(&[124, 1, 25]) { return Some((0, true)); }
    if data.starts_with(&[0, 0, 0, 1, 25]) { return Some((4, false)); }
    if data.starts_with(&[0, 0, 1, 25]) { return Some((3, false)); }
    if data.starts_with(&[0, 1, 25]) { return Some((2, false)); }
    if data.starts_with(&[1, 25]) { return Some((1, false)); }
    if data.starts_with(&[25]) { return Some((0, false)); }
    None
}

fn parse_container(data: &[u8], kind: RpuContainer) -> anyhow::Result<DoviRpu> {
    let unwrapped = &data[kind.prefix..];
    match kind.encoding {
        RpuEncoding::Raw => DoviRpu::parse_rpu(unwrapped),
        RpuEncoding::EmulationPrevented => {
            // libdovi accepts both 7C01 HEVC NAL and 19-prefixed raw RPU.
            DoviRpu::parse_unspec62_nalu(unwrapped)
        }
    }
}

fn to_bytes(rpu: &DoviRpu, kind: RpuContainer, original: &[u8]) -> anyhow::Result<Vec<u8>> {
    let payload = match kind.encoding {
        RpuEncoding::Raw => rpu.write_rpu()?,
        RpuEncoding::EmulationPrevented => {
            // Generates 7C01 + EPB-protected payload. If Apple provided only
            // the 19-prefixed payload, remove the generated NAL header.
            let nal = rpu.write_hevc_unspec62_nalu()?;
            if kind.nal_header {
                nal
            } else {
                nal[2..].to_vec()
            }
        }
    };
    // Reconstruct the original Annex-B, short, or bare container unchanged.
    let mut output = Vec::with_capacity(kind.prefix + payload.len() + 2);
    output.extend_from_slice(&original[..kind.prefix]);
    if kind.nal_header && matches!(kind.encoding, RpuEncoding::Raw) {
        // Raw parsing always receives 19-prefixed RPU bytes, i.e. the HEVC
        // NAL header must be stripped and restored outside the parser.
        // We prefer EPB parsing for NAL source, so skip raw here instead.
        unreachable!("raw NAL must not be chosen");
    }
    output.extend_from_slice(&payload);
    Ok(output)
}

fn parse_exact_roundtrip(data: &[u8]) -> Result<(DoviRpu, RpuContainer), i32> {
    let (prefix, nal_header) = identify_wrapper(data).ok_or(-9)?;
    let mut parsed_any = false;
    // On a true 7C01 HEVC NALU, the EPB-aware parser is mandatory; otherwise
    // attempt BOTH forms because 19-prefixed payloads may also carry EPB.
    let encodings: &[RpuEncoding] = if nal_header {
        &[RpuEncoding::EmulationPrevented]
    } else {
        &[RpuEncoding::Raw, RpuEncoding::EmulationPrevented]
    };
    for &encoding in encodings {
        let kind = RpuContainer { prefix, nal_header, encoding };
        if let Ok(rpu) = parse_container(data, kind) {
            parsed_any = true;
            if let Ok(roundtrip) = to_bytes(&rpu, kind, data) {
                if roundtrip == data {
                    return Ok((rpu, kind));
                }
            }
        }
    }
    Err(if parsed_any { -3 } else { -5 })
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
    let (mut rpu, kind) = match parse_exact_roundtrip(data) {
        Ok(pair) => pair,
        Err(code) => {
            if !status.is_null() { unsafe { *status = code; } }
            return 0;
        }
    };

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
