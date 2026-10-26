import Foundation

func expect(_ ok: @autoclosure () -> Bool, _ message: String) {
    if !ok() { fatalError(message) }
}

let expr = NuvioBlackBarProtection.videoFilter(
    contrast: 0.75, brightness: 1.5, saturation: 1.2)
expect(expr.contains("lutyuv=y=val+"), "Black-level-protecting luma expression must be used")
expect(expr.contains("abs("), "Luma-level black-matte detection must be present")
expect(!expr.contains(","), "FFmpeg filter-graph must not contain unescaped commas")
for range in [255.0, 1023.0] {
    // Covers full-range black and the legal-range black pedestal, at 8/10 bit.
    let studioBlack = (range + 1) / 16
    for black in [0.0, studioBlack, (range + 1) * 0.08] {
        for contrast in [0.70, 1.0, 1.40] {
            for brightness in [0.70, 1.0, 1.50] {
                let adjusted = NuvioBlackBarProtection.adjustedLuma(
                    black, maxValue: range, contrast: contrast,
                    brightness: brightness)
                expect(abs(adjusted - black) < 0.000001,
                    "Black matting must remain unchanged with any brightness/contrast")
            }
        }
    }
    let gray = (range + 1) * 0.55
    expect(NuvioBlackBarProtection.adjustedLuma(gray, maxValue: range,
        contrast: 1.0, brightness: 1.5) > gray,
        "Normal picture must still respond to brightness")
    let shadow = (range + 1) * 0.20
    expect(NuvioBlackBarProtection.adjustedLuma(shadow, maxValue: range,
        contrast: 0.7, brightness: 1.0) > shadow,
        "Normal picture must still respond to reduced contrast")
}
print("Nuvio SDR/HDR black-matte luma guard: PASS")
