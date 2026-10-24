import Foundation

/// Protects the actual black pixels in source-encoded letterboxing/pillarboxing.
///
/// Using a per-luma-sample guard rather than estimating a crop rectangle means
/// moving mattes and irregular borders stay protected too. It also avoids
/// black masks accidentally covering real video during dark scenes, zoom or
/// vertical stretch. No extra video decoder, sample read-back or overlay is
/// needed. Native display letterboxes are already black and are unaffected.
///
/// The tiny safe band includes the studio-range YUV black pedestal (16/255 or
/// 64/1023), full-range black (0), and modest compression noise. Changes to
/// luma smoothly fade in above this level, retaining adjustments to picture
/// details while never lifting the encoded black matte. FFmpeg's LUT filter
/// precomputes the expression, so this adds no per-frame image traversal.
///
/// Dolby Vision never calls this filter. HDR10/HLG uses this only with the
/// existing experimental HDR processing opt-in.
enum NuvioBlackBarProtection {
    // Greater than limited-range 16/255 (and 64/1023), but only barely:
    // black bars with mild encoding noise remain at their untouched level.
    static let blackThreshold = 0.085
    // Soft transition avoids visible contours/banding around black.
    static let transition = 0.012

    /// Legal FFmpeg `lutyuv=y=` expression, with no unescaped commas or
    /// graph separators. One expression works with both 8- and 10-bit YUV.
    static func protectedLumaExpression(contrast: Double, brightness: Double) -> String {
        let deltaContrast = contrast - 1.0
        let lumaLift = (brightness - 1.0) * 0.35
        let threshold = String(format: "%.6f", blackThreshold)
        let softness = String(format: "%.6f", transition)
        let distance = "(val-(maxval+1)*\(threshold))"
        // positivePart = max(val - threshold, 0), without FFmpeg-graph
        // commas that would be parsed as the start of another filter.
        let positive = "((\(distance)+abs(\(distance)))/2)"
        let weight = "(\(positive)/(\(positive)+(maxval+1)*\(softness)))"
        // Exactly reproduces the prior image adjustment above the matte,
        // except for its progressive near-black weighting.
        let adjust = String(format:
            "((val-(maxval+1)/2)*%.6f+(maxval+1)*%.6f)",
            deltaContrast, lumaLift)
        return "val+\(weight)*\(adjust)"
    }

    /// The mpvRx Vivid preset consists of NaturalColors (Y^1.2, I/Q * 1.2)
    /// followed by neutral Levels. tvOS's native AVFoundation video output
    /// does not run mpvRx's GLSL hooks, so use FFmpeg's precomputed YUV LUT
    /// as an approximation. The lightness exponent is exactly 1.2; YUV U/V
    /// chroma gain is equivalent in intent to the YIQ chroma gain but is NOT
    /// bit-exact RGB/YIQ shader output. Do not bypass DV hardware output.
    ///
    /// YUV encoded black is not a zero-valued sample. Preserve both full-
    /// and legal-range near-black values using the same matte guard as the
    /// manual brightness/contrast controls. This avoids illuminating OLED bars.
    static func vividLumaExpression() -> String {
        let range = "(maxval+1)"
        let threshold = String(format: "%.6f", blackThreshold)
        let soft = String(format: "%.6f", transition)
        let distance = "(val-\(range)*\(threshold))"
        let above = "((\(distance)+abs(\(distance)))/2)"
        let weight = "(\(above)/(\(above)+\(range)*\(soft)))"
        let normalized = "(\(above)/(\(range)*(1-\(threshold))))"
        // Avoid the argument commas of pow()/max() in the nested mpv lavfi
        // parser. exp(a*log(x)) is mathematically equivalent to pow(x,a).
        // The epsilon prevents log(0); weight is zero for any black-bar value.
        let curve = "exp(1.2*log(\(normalized)+0.000001))"
        return "(\(range)*\(weight)*(\(curve)-\(normalized)))"
    }

    static func videoFilter(contrast: Double, brightness: Double,
                            saturation: Double, vivid: Bool = false) -> String {
        let ordinary = protectedLumaExpression(contrast: contrast, brightness: brightness)
        let y = vivid ? "\(ordinary)+\(vividLumaExpression())" : ordinary
        let chroma = saturation * (vivid ? 1.2 : 1.0)
        return String(format:
            "@nuvio-color:lavfi=[lutyuv=y=%@:u=(val-(maxval+1)/2)*%.4f+(maxval+1)/2:v=(val-(maxval+1)/2)*%.4f+(maxval+1)/2]",
            y, chroma, chroma)
    }

    static func adjustedVividLuma(_ value: Double, maxValue: Double) -> Double {
        let range = maxValue + 1
        let above = max(0, value - range * blackThreshold)
        if above == 0 { return value }
        let x = above / (range * (1 - blackThreshold))
        let weight = above / (above + range * transition)
        return value + range * weight * (pow(x, 1.2) - x)
    }

    /// Reference model used in tests for studio- and full-range black.
    static func adjustedLuma(_ value: Double, maxValue: Double,
                             contrast: Double, brightness: Double) -> Double {
        let range = maxValue + 1
        let aboveBlack = max(0, value - range * blackThreshold)
        let weight = aboveBlack / (aboveBlack + range * transition)
        let adjustment = (value - range / 2) * (contrast - 1)
            + range * (brightness - 1) * 0.35
        return value + weight * adjustment
    }
}
