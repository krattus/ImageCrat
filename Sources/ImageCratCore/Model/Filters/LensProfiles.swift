import Foundation

/// Lens-profile corrections for Filter ▸ Lens Correction: radial distortion, transverse chromatic aberration and vignetting.
///
/// Profile coefficients are transcribed from the lensfun database (https://github.com/lensfun/lensfun, data/db/*.xml,
/// © lensfun contributors, licensed CC BY-SA 3.0). Each entry uses the calibration at the lens' widest focal length
/// (vignetting: widest aperture, distance 1000). Model conventions follow lensfun:
///  - distortion "ptlens": r_d = r_u · (a·r_u³ + b·r_u² + c·r_u + 1 − a − b − c); "poly3" (k1) is the special case a=0, b=k1, c=0.
///    r is normalized so that 1 = half of the shorter image side.
///  - TCA "poly3": r_red = r · (vr + br·r²), r_blue = r · (vb + bb·r²) relative to green, same normalization.
///  - vignetting "pa": C_d = C_s · (1 + k1·r² + k2·r⁴ + k3·r⁶), r normalized to half the image diagonal.
/// The image is assumed to match the calibration crop factor.
package struct LensProfile {
    package var name: String
    package var abc: (Double, Double, Double)
    package var tca: (vr: Double, br: Double, vb: Double, bb: Double)? = nil
    package var vignette: (Double, Double, Double)? = nil
    package init(name: String, abc: (Double, Double, Double), tca: (vr: Double, br: Double, vb: Double, bb: Double)? = nil, vignette: (Double, Double, Double)? = nil) {
        self.name = name; self.abc = abc; self.tca = tca; self.vignette = vignette
    }
}

package enum LensProfiles {
    package static let all: [LensProfile] = [
        LensProfile(name: "Canon EF 16-35mm f/2.8L II USM @ 16mm", abc: (0.0065, -0.01669, -0.01549),
                    tca: (1.0003744, 0.0000346, 0.9998434, 0.0000537), vignette: (-0.2764, -1.2603, 0.7727)),
        LensProfile(name: "Canon EF 24-105mm f/4L IS USM @ 24mm", abc: (0.017263, -0.049244, 0),
                    tca: (1.0011673, -0.0000336, 1.0001820, -0.0000857), vignette: (-0.5460, -0.2245, -0.0825)),
        LensProfile(name: "Canon EF 50mm f/1.8 II", abc: (0.00163, -0.01449, 0.01568),
                    tca: (1.0000353, -0.0000048, 1.0000073, -0.0000112), vignette: (-1.4745, 1.1285, -0.4284)),
        LensProfile(name: "Nikon AF-S 14-24mm f/2.8G ED @ 14mm", abc: (0, -0.01343, 0),
                    tca: (1.0001266, 0.0000628, 1.0001134, -0.0000429)),
        LensProfile(name: "Nikon AF-S 50mm f/1.8G", abc: (0.00535901, -0.0245905, 0.0239742),
                    vignette: (-1.4824, 1.2052, -0.4588)),
        LensProfile(name: "Nikon AF-P DX 18-55mm f/3.5-5.6G VR @ 18mm", abc: (0.01368, -0.06635, 0.05634),
                    tca: (1.0000132, 0, 0.9999439, 0), vignette: (-1.6356, 1.4231, -0.5427)),
        LensProfile(name: "Sony FE 28-70mm f/3.5-5.6 OSS @ 28mm", abc: (0.00900771, -0.0310341, 0.00110802),
                    tca: (1.0005795, -0.0001882, 0.9997320, 0.0001886), vignette: (-1.2040, 0.7047, -0.2263)),
        LensProfile(name: "Sony FE 16-35mm f/4 ZA OSS @ 16mm", abc: (0.00561, -0.00446, -0.04348),
                    tca: (1.0000279, 0.0001100, 1.0001669, -0.0000788), vignette: (-1.1889, 0.5519, -0.1590)),
        LensProfile(name: "Fujifilm XF 18-55mm f/2.8-4 R LM OIS @ 18mm", abc: (0.02808, -0.10604, 0.07041),
                    tca: (1.0006600, -0.0001885, 0.9998316, 0.0001738), vignette: (-0.9940, 0.9214, -0.6090)),
    ]

    /// Choice labels for the "profile" parameter (index 0 = none).
    package static var menuNames: [String] { ["None"] + all.map(\.name) }
}
