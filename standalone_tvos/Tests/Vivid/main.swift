import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let off = NuvioBlackBarProtection.videoFilter(
    contrast: 1, brightness: 1, saturation: 1)
let on = NuvioBlackBarProtection.videoFilter(
    contrast: 1, brightness: 1, saturation: 1, vivid: true)
expect(on != off, "Vivid must change the filter even when sliders are neutral")
expect(on.contains("exp(1.2*log("), "mpvRx default luma power must be used")
expect(on.contains("*1.2000+"), "mpvRx default 1.2 chroma must be used")
expect(!off.contains("exp(1.2*log("), "Vivid OFF must not alter existing color")
expect(!on.contains(","), "Nested FFmpeg expression must not contain unescaped commas")
for range in [255.0, 1023.0] {
    for black in [0.0, (range + 1) / 16, (range + 1) * 0.08] {
        let converted = NuvioBlackBarProtection.adjustedVividLuma(black, maxValue: range)
        expect(abs(converted - black) < 0.0000001, "Legal/full black must be preserved")
    }
    let mid = (range + 1) * 0.55
    expect(NuvioBlackBarProtection.adjustedVividLuma(mid, maxValue: range) < mid,
           "Vivid 1.2 luma curve must visibly adjust midtones")
    let white = range
    expect(abs(NuvioBlackBarProtection.adjustedVividLuma(white, maxValue: range) - white) < 2,
           "Vivid should preserve the white point")
}
print("Vivid LUT 1.2 luma/chroma, neutral-off, OLED-black guard: PASS")
