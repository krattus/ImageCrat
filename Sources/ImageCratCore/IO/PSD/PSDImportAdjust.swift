import Foundation

// Adjustment layers: each kind is a tagged block with its own small binary layout (or a descriptor in newer ones).

package enum PSDAdjust {
    package enum Outcome {
        /// Settings, plus a note when something was approximated.
        case ok(AdjustmentSettings, String?)
        case unsupported(String)
    }

    /// Block keys in the order they are looked for ('CgEd' and 'brit' both describe Brightness/Contrast).
    package static let keys = ["levl", "curv", "CgEd", "brit", "blnc", "hue2", "hue ", "selc", "mixr", "grdm", "phfl", "expA", "vibA", "blwh", "post", "thrs", "nvrt", "clrL"]

    package static func key(of r: PSDRecord) -> String? { keys.first { r.has($0) } }

    package static func settings(_ key: String, _ r: PSDRecord, _ imp: any PSDByteSource) -> Outcome {
        guard let b = r.block(key) else { return .unsupported("missing data") }
        var c = PSDCursor(imp.bytes, b)
        do {
            switch key {
            case "levl": return try levels(&c)
            case "curv": return try curves(&c)
            case "CgEd", "brit": return try brightness(r, imp)
            case "blnc": return try colorBalance(&c)
            case "hue2", "hue ": return try hueSaturation(&c)
            case "selc": return try selectiveColor(&c)
            case "mixr": return try channelMixer(&c)
            case "grdm": return try gradientMap(&c)
            case "phfl": return try photoFilter(&c)
            case "expA": return try exposure(&c)
            case "vibA":
                guard let d = imp.descriptor(b) else { throw PSDImportError.invalid("vibrance") }
                var s = AdjustmentSettings(kind: .vibrance)
                s.vibrance = clamp(d.double("vibrance") ?? 0, -100, 100)
                s.saturation = clamp(d.double("Strt") ?? 0, -100, 100)
                return .ok(s, nil)
            case "blwh":
                guard let d = imp.descriptor(b) else { throw PSDImportError.invalid("black & white") }
                var s = AdjustmentSettings(kind: .blackWhite)
                func w(_ k: String, _ def: Double) -> Double { clamp(d.double(k) ?? def, -200, 300) }
                s.bwReds = w("Rd  ", 40); s.bwYellows = w("Yllw", 60); s.bwGreens = w("Grn ", 40)
                s.bwCyans = w("Cyn ", 60); s.bwBlues = w("Bl  ", 20); s.bwMagentas = w("Mgnt", 80)
                s.bwTint = d.bool("useTint") ?? false
                if let t = PSDLayerStyle.parseColor(d.object("tintColor")) { s.bwTintColor = t }
                return .ok(s, nil)
            case "post":
                var s = AdjustmentSettings(kind: .posterize)
                s.posterizeLevels = Double(clamp(try c.u16(), 2, 255))
                return .ok(s, nil)
            case "thrs":
                var s = AdjustmentSettings(kind: .threshold)
                s.thresholdLevel = Double(clamp(try c.u16(), 1, 255))
                return .ok(s, nil)
            case "nvrt": return .ok(AdjustmentSettings(kind: .invert), nil)
            case "clrL":
                let d = imp.descriptor(b, skip: 2) ?? imp.descriptor(b)
                let name = d?.string("Nm  ") ?? d?.string("LUT3DFileName") ?? ""
                return .unsupported("Color Lookup\(name.isEmpty ? "" : " “\(name)”") uses a 3D LUT / ICC profile ImageCrat cannot load; the layer was left out.")
            default: return .unsupported("unknown adjustment “\(key)”")
            }
        } catch {
            return .unsupported("The \(key) settings are damaged (\(error)); the layer was left out.")
        }
    }

    package static func levels(_ c: inout PSDCursor) throws -> Outcome {
        guard try c.u16() == 2 else { throw PSDImportError.unsupported("levels version") }
        var s = AdjustmentSettings(kind: .levels)
        // records: composite, then one per channel (R, G, B)
        for i in 0..<4 {
            let inB = try c.u16(), inW = try c.u16(), outB = try c.u16(), outW = try c.u16(), g = try c.u16()
            var ch = LevelsChannel()
            ch.inBlack = Double(clamp(inB, 0, 253)); ch.inWhite = Double(clamp(inW, inB + 2, 255))
            ch.outBlack = Double(clamp(outB, 0, 255)); ch.outWhite = Double(clamp(outW, 0, 255))
            ch.gamma = clamp(Double(g) / 100, 0.1, 9.99)
            s.levels[i] = ch
        }
        return .ok(s, nil)
    }

    package static func curves(_ c: inout PSDCursor) throws -> Outcome {
        let isMap = try c.u8() == 1
        let version = try c.u16()
        let mask = try c.u32()
        var s = AdjustmentSettings(kind: .curves)
        var note: String? = nil
        func curve() throws -> [CGPoint] {
            var pts: [CGPoint] = []
            if isMap {
                // freehand map: 256 output values — sampled down to a smooth curve
                let r = try c.take(256)
                for i in stride(from: 0, through: 255, by: 15) { pts.append(CGPoint(x: Double(i) / 255, y: Double(c.bytes[r.lowerBound + i]) / 255)) }
                note = "A pencil-drawn curve was approximated with 18 points."
            } else {
                let n = try c.u16()
                guard n <= 64 else { throw PSDImportError.invalid("curve point count") }
                for _ in 0..<n {
                    let out = try c.u16(), inp = try c.u16()
                    pts.append(CGPoint(x: Double(clamp(inp, 0, 255)) / 255, y: Double(clamp(out, 0, 255)) / 255))
                }
            }
            return pts.sorted { $0.x < $1.x }
        }
        // channel 0 = composite, 1… = R, G, B. Version 1 stores a bit mask of the curves present, version 4 a count
        // with the channel index in front of each curve.
        if version == 4 {
            for _ in 0..<min(mask, 32) {
                let ch = try c.u16()
                let pts = try curve()
                if ch < 4, pts.count >= 2 { s.curves[ch] = CurvePoints(points: pts) }
            }
        } else {
            for ch in 0..<32 where mask & (1 << ch) != 0 {
                let pts = try curve()
                if ch < 4, pts.count >= 2 { s.curves[ch] = CurvePoints(points: pts) }
            }
        }
        return .ok(s, note)
    }

    package static func brightness(_ r: PSDRecord, _ imp: any PSDByteSource) throws -> Outcome {
        var s = AdjustmentSettings(kind: .brightnessContrast)
        if let b = r.block("CgEd"), let d = imp.descriptor(b) {
            s.brightness = clamp(d.double("Brgh") ?? 0, -150, 150)
            s.contrast = clamp(d.double("Cntr") ?? 0, -50, 100)
            return .ok(s, d.bool("useLegacy") == true ? "“Use Legacy” is on in Photoshop; ImageCrat uses its standard curve." : nil)
        }
        guard let b = r.block("brit") else { throw PSDImportError.invalid("brightness") }
        var c = PSDCursor(imp.bytes, b)
        s.brightness = Double(clamp(try c.i16(), -150, 150))
        s.contrast = Double(clamp(try c.i16(), -50, 100))
        return .ok(s, nil)
    }

    package static func colorBalance(_ c: inout PSDCursor) throws -> Outcome {
        var s = AdjustmentSettings(kind: .colorBalance)
        func triple() throws -> ToneTriple {
            ToneTriple(cyanRed: Double(clamp(try c.i16(), -100, 100)), magentaGreen: Double(clamp(try c.i16(), -100, 100)), yellowBlue: Double(clamp(try c.i16(), -100, 100)))
        }
        s.shadows = try triple(); s.midtones = try triple(); s.highlights = try triple()
        s.preserveLuminosity = ((try? c.u8()) ?? 1) != 0
        return .ok(s, nil)
    }

    package static func hueSaturation(_ c: inout PSDCursor) throws -> Outcome {
        guard try c.u16() == 2 else { throw PSDImportError.unsupported("hue/saturation version") }
        var s = AdjustmentSettings(kind: .hueSaturation)
        s.colorize = try c.u8() != 0
        try c.skip(1)
        let cHue = try c.i16(), cSat = try c.i16(), cLight = try c.i16()
        let mHue = try c.i16(), mSat = try c.i16(), mLight = try c.i16()
        if s.colorize {
            // Photoshop: hue 0…360, saturation 0…100 (25 = default). Lumen: hue ±180 (negative wraps), 0 = the 25 % default.
            let h = Double(((cHue % 360) + 360) % 360)
            s.hue = h > 180 ? h - 360 : h
            s.hsSaturation = clamp(Double(cSat) * 4 - 100, -100, 100)
            s.lightness = Double(clamp(cLight, -100, 100))
        } else {
            s.hue = Double(clamp(mHue, -180, 180)); s.hsSaturation = Double(clamp(mSat, -100, 100)); s.lightness = Double(clamp(mLight, -100, 100))
        }
        // six colour ranges: 4 range values (degrees), then hue / saturation / lightness
        var ranges = HueRange.defaults
        for i in 0..<6 {
            guard c.remaining >= 14 else { break }
            let rv = [try c.i16(), try c.i16(), try c.i16(), try c.i16()].map(Double.init)
            let h = try c.i16(), sa = try c.i16(), li = try c.i16()
            var hr = HueRange(range: HueRange.defaultRanges[i])
            if rv.contains(where: { $0 != 0 }) { hr.range = rv }
            hr.hue = Double(clamp(h, -180, 180)); hr.saturation = Double(clamp(sa, -100, 100)); hr.lightness = Double(clamp(li, -100, 100))
            ranges[i] = hr
        }
        s.hsRanges = ranges
        return .ok(s, nil)
    }

    package static func selectiveColor(_ c: inout PSDCursor) throws -> Outcome {
        guard try c.u16() == 1 else { throw PSDImportError.unsupported("selective colour version") }
        var s = AdjustmentSettings(kind: .selectiveColor)
        s.selectiveAbsolute = try c.u16() == 1
        try c.skip(8)   // first record is reserved
        for i in 0..<9 {
            func v() throws -> Double { Double(clamp(try c.i16(), -100, 100)) }
            s.selective[i] = SelectiveColorEntry(cyan: try v(), magenta: try v(), yellow: try v(), black: try v())
        }
        return .ok(s, nil)
    }

    package static func channelMixer(_ c: inout PSDCursor) throws -> Outcome {
        guard try c.u16() == 1 else { throw PSDImportError.unsupported("channel mixer version") }
        var s = AdjustmentSettings(kind: .channelMixer)
        s.monochrome = try c.u16() != 0
        // per output channel: red, green, blue, (black), constant
        func row() throws -> [Double] {
            let r = try c.i16(), g = try c.i16(), b = try c.i16()
            try c.skip(2)
            let k = try c.i16()
            return [r, g, b, k].map { Double(clamp($0, -200, 200)) }
        }
        s.mixRed = try row()
        if !s.monochrome, c.remaining >= 20 { s.mixGreen = try row(); s.mixBlue = try row() }
        return .ok(s, nil)
    }

    package static func gradientMap(_ c: inout PSDCursor) throws -> Outcome {
        let version = try c.u16()
        guard version == 1 || version == 3 else { throw PSDImportError.unsupported("gradient map version \(version)") }
        var s = AdjustmentSettings(kind: .gradientMap)
        s.gradientReverse = try c.u8() != 0
        try c.skip(1)   // dither
        // version 3 adds an interpolation-method field whose size is not documented: take the layout that parses cleanly
        for extra in (version == 3 ? [4, 0, 2] : [0]) {
            var t = c
            guard (try? t.skip(extra)) != nil, let g = try? stops(&t) else { continue }
            s.gradient = g
            return .ok(s, nil)
        }
        throw PSDImportError.invalid("gradient map stops")
    }

    private static func stops(_ c: inout PSDCursor) throws -> ColorGradient {
        let name = try c.unicode()
        let nc = try c.u16()
        guard (1...256).contains(nc) else { throw PSDImportError.invalid("gradient stops") }
        var colors: [(Double, RGBA)] = []
        for _ in 0..<nc {
            let loc = try c.u32()
            guard loc <= 4096 else { throw PSDImportError.invalid("gradient stop location") }
            try c.skip(4)   // midpoint
            let space = try c.u16()
            let v = [try c.u16(), try c.u16(), try c.u16(), try c.u16()].map { Double($0) / 65535 }
            try c.skip(2)
            let col: RGBA
            switch space {
            case 1: col = RGBA(h: v[0], s: v[1], v: v[2])
            case 2: col = RGBA(r: v[0] * v[3], g: v[1] * v[3], b: v[2] * v[3])   // CMYK, stored inverted
            case 8: col = RGBA(gray: clamp(1 - v[0] * 65535 / 10000, 0, 1))
            default: col = RGBA(r: v[0], g: v[1], b: v[2])
            }
            colors.append((Double(loc) / 4096, col))
        }
        let nt = try c.u16()
        guard nt <= 256 else { throw PSDImportError.invalid("gradient stops") }
        var alphas: [(Double, Double)] = []
        for _ in 0..<nt {
            let loc = try c.u32()
            guard loc <= 4096 else { throw PSDImportError.invalid("gradient stop location") }
            try c.skip(4)
            alphas.append((Double(loc) / 4096, clamp(Double(try c.u16()) / 255, 0, 1)))
        }
        colors.sort { $0.0 < $1.0 }; alphas.sort { $0.0 < $1.0 }
        func alpha(_ t: Double) -> Double {
            guard let f = alphas.first, let l = alphas.last else { return 1 }
            if t <= f.0 { return f.1 }
            if t >= l.0 { return l.1 }
            for i in 0..<(alphas.count - 1) where t >= alphas[i].0 && t <= alphas[i + 1].0 {
                return alphas[i].1 + (alphas[i + 1].1 - alphas[i].1) * (t - alphas[i].0) / max(1e-9, alphas[i + 1].0 - alphas[i].0)
            }
            return l.1
        }
        return ColorGradient(name: name.isEmpty ? "Gradient Map" : name, stops: colors.map { var col = $0.1; col.a = alpha($0.0); return GradientStop(location: $0.0, color: col) })
    }

    package static func photoFilter(_ c: inout PSDCursor) throws -> Outcome {
        let version = try c.u16()
        var s = AdjustmentSettings(kind: .photoFilter)
        var note: String? = nil
        if version == 3 {
            // CIE XYZ, 4 bytes per component. The fixed-point scale is not documented: read it as 16.16 and, when that
            // leaves the colour out of range, keep the chromaticity and normalise the brightness.
            let x = Double(try c.i32()) / 65536, y = Double(try c.i32()) / 65536, z = Double(try c.i32()) / 65536
            let m = max(3.1339 * x - 1.6169 * y - 0.4906 * z, -0.9785 * x + 1.9160 * y + 0.0333 * z, 0.0720 * x - 0.2290 * y + 1.4057 * z)
            if m > 1.02 || m < 0.02 {
                guard m > 0 else { return .ok(s, "The filter colour could not be read; the default warming colour is used.") }
                s.filterColor = PSDAdjust.xyzColor(x / m, y / m, z / m)
                note = "The filter colour's brightness is approximated."
            } else {
                s.filterColor = PSDAdjust.xyzColor(x, y, z)
            }
        } else if version == 2 {
            let space = try c.u16()
            let v = [try c.u16(), try c.u16(), try c.u16(), try c.u16()]
            switch space {
            case 0: s.filterColor = RGBA(r: Double(v[0]) / 65535, g: Double(v[1]) / 65535, b: Double(v[2]) / 65535)
            case 7:
                // Lab: L 0…10000, a/b -12800…12700
                let d = PSDDescriptor(classID: "LbCl", [("Lmnc", .double(Double(v[0]) / 100)), ("A   ", .double(Double(Int16(truncatingIfNeeded: v[1])) / 100)),
                                                       ("B   ", .double(Double(Int16(truncatingIfNeeded: v[2])) / 100))])
                s.filterColor = PSDLayerStyle.parseColor(d) ?? s.filterColor
            default: return .ok(s, "The filter colour uses a colour space that is not read; the default warming colour is used.")
            }
        } else {
            throw PSDImportError.unsupported("photo filter version \(version)")
        }
        s.density = Double(clamp(try c.i32(), 1, 100))
        s.preserveLuminosity = ((try? c.u8()) ?? 1) != 0
        return .ok(s, note)
    }

    /// XYZ (D50, Y = 1 white) → sRGB.
    package static func xyzColor(_ X: Double, _ Y: Double, _ Z: Double) -> RGBA {
        let lr = 3.1339 * X - 1.6169 * Y - 0.4906 * Z
        let lg = -0.9785 * X + 1.9160 * Y + 0.0333 * Z
        let lb = 0.0720 * X - 0.2290 * Y + 1.4057 * Z
        func gamma(_ v: Double) -> Double { let x = clamp(v, 0, 1); return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
        return RGBA(r: gamma(lr), g: gamma(lg), b: gamma(lb))
    }

    package static func exposure(_ c: inout PSDCursor) throws -> Outcome {
        guard try c.u16() == 1 else { throw PSDImportError.unsupported("exposure version") }
        var s = AdjustmentSettings(kind: .exposure)
        let e = try c.f32(), o = try c.f32(), g = try c.f32()
        guard e.isFinite, o.isFinite, g.isFinite else { throw PSDImportError.invalid("exposure values") }
        s.exposure = clamp(e, -20, 20); s.offset = clamp(o, -0.5, 0.5); s.gamma = clamp(g, 0.01, 9.99)
        return .ok(s, nil)
    }
}
