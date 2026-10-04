import Foundation

// Adjustment layers → Photoshop's adjustment blocks (the inverse of PSDAdjust). Kinds without a Photoshop
// adjustment layer return `why`, and the exporter bakes them into a pixel layer.

package enum PSDExportAdjust {
    package struct Encoded {
        package var blocks: [(String, Data)]?
        /// Set when the Photoshop settings only approximate Lumen's.
        package var note: String? = nil
        /// Set when there is no Photoshop equivalent.
        package var why: String? = nil
        package init(blocks: [(String, Data)]? = nil, note: String? = nil, why: String? = nil) {
            self.blocks = blocks; self.note = note; self.why = why
        }
    }

    private static func fin(_ v: Double, _ d: Double = 0) -> Double { v.isFinite ? v : d }
    private static func i16(_ v: Double, _ lo: Double, _ hi: Double) -> Int16 { Int16(clamp(fin(v), lo, hi).rounded()) }

    package static func encode(_ s: AdjustmentSettings) -> Encoded {
        switch s.kind {
        case .brightnessContrast:
            let b = i16(s.brightness, -150, 150), c = i16(s.contrast, -50, 100)
            // 'brit' holds the legacy algorithm's values: Photoshop leaves it zero and keeps the settings in 'CgEd'
            let brit = Data(count: 8)
            let d = PSDDescriptor(classID: "null", [("Vrsn", .integer(1)), ("Brgh", .integer(Int32(b))), ("Cntr", .integer(Int32(c))),
                                                    ("means", .integer(127)), ("Lab ", .bool(false)), ("useLegacy", .bool(false)), ("Auto", .bool(false))])
            return Encoded(blocks: [("brit", brit), ("CgEd", d.serializedVersioned())])
        case .levels:
            return Encoded(blocks: [("levl", levels(s))])
        case .curves:
            return Encoded(blocks: [("curv", curves(s))])
        case .exposure:
            var w = BinaryWriter()
            w.u16(1)
            w.u32(Float(clamp(fin(s.exposure), -20, 20)).bitPattern)
            w.u32(Float(clamp(fin(s.offset), -0.5, 0.5)).bitPattern)
            w.u32(Float(clamp(fin(s.gamma, 1), 0.01, 9.99)).bitPattern)
            return Encoded(blocks: [("expA", w.data)])
        case .vibrance:
            let d = PSDDescriptor(classID: "null", [("vibrance", .integer(Int32(i16(s.vibrance, -100, 100)))), ("Strt", .integer(Int32(i16(s.saturation, -100, 100))))])
            return Encoded(blocks: [("vibA", d.serializedVersioned())])
        case .hueSaturation:
            return Encoded(blocks: [("hue2", hueSaturation(s))])
        case .colorBalance:
            var w = BinaryWriter()
            for t in [s.shadows, s.midtones, s.highlights] {
                w.i16(i16(t.cyanRed, -100, 100)); w.i16(i16(t.magentaGreen, -100, 100)); w.i16(i16(t.yellowBlue, -100, 100))
            }
            w.u8(s.preserveLuminosity ? 1 : 0); w.u8(0)
            return Encoded(blocks: [("blnc", w.data)])
        case .blackWhite:
            func n(_ v: Double, _ d: Double) -> PSDDescriptorValue { .integer(Int32(clamp(fin(v, d), -200, 300).rounded())) }
            let d = PSDDescriptor(classID: "null", [
                ("Rd  ", n(s.bwReds, 40)), ("Yllw", n(s.bwYellows, 60)), ("Grn ", n(s.bwGreens, 40)), ("Cyn ", n(s.bwCyans, 60)),
                ("Bl  ", n(s.bwBlues, 20)), ("Mgnt", n(s.bwMagentas, 80)), ("useTint", .bool(s.bwTint)), ("tintColor", rgb(s.bwTintColor)),
                ("bwPresetKind", .integer(1)), ("blackAndWhitePresetFileName", .string("")),
            ])
            return Encoded(blocks: [("blwh", d.serializedVersioned())])
        case .photoFilter:
            // version 2: colour space 0 (RGB) + four 16-bit components, density, preserve luminosity
            var w = BinaryWriter()
            w.u16(2); w.u16(0)
            let c = s.filterColor
            for v in [c.r, c.g, c.b] { w.u16(UInt16(clamp(fin(v), 0, 1) * 65535 + 0.5)) }
            w.u16(0)
            w.i32(Int32(clamp(fin(s.density, 25), 1, 100).rounded()))
            w.u8(s.preserveLuminosity ? 1 : 0); w.u8(0)
            return Encoded(blocks: [("phfl", w.data)])
        case .channelMixer:
            return Encoded(blocks: [("mixr", mixer(s.monochrome, s.mixRed, s.mixGreen, s.mixBlue))])
        case .invert:
            return Encoded(blocks: [("nvrt", Data())])
        case .posterize:
            var w = BinaryWriter(); w.u16(UInt16(clamp(fin(s.posterizeLevels, 4), 2, 255).rounded())); w.u16(0)
            return Encoded(blocks: [("post", w.data)])
        case .threshold:
            var w = BinaryWriter(); w.u16(UInt16(clamp(fin(s.thresholdLevel, 128), 1, 255).rounded())); w.u16(0)
            return Encoded(blocks: [("thrs", w.data)])
        case .gradientMap:
            return Encoded(blocks: [("grdm", gradientMap(s.gradient, reverse: s.gradientReverse))])
        case .selectiveColor:
            var w = BinaryWriter()
            w.u16(1); w.u16(s.selectiveAbsolute ? 1 : 0)
            w.bytes([0, 0, 0, 0, 0, 0, 0, 0])   // first record is reserved
            for i in 0..<9 {
                let e = i < s.selective.count ? s.selective[i] : SelectiveColorEntry()
                for v in [e.cyan, e.magenta, e.yellow, e.black] { w.i16(i16(v, -100, 100)) }
            }
            return Encoded(blocks: [("selc", w.data)])
        case .desaturate:
            // Lumen desaturates to luminance (Rec. 709 weights); a monochrome Channel Mixer gives the same result,
            // where Hue/Saturation −100 would use Photoshop's (max + min) / 2 lightness instead.
            return Encoded(blocks: [("mixr", mixer(true, [21, 72, 7, 0], [0, 100, 0, 0], [0, 0, 100, 0]))],
                           note: "Desaturate is written as a monochrome Channel Mixer (21 % red, 72 % green, 7 % blue), which matches ImageCrat's luminance desaturation.")
        case .shadowsHighlights:
            return Encoded(blocks: nil, why: "Photoshop has Shadows/Highlights only as a destructive command or smart filter, not as an adjustment layer; the adjusted picture is stored as pixels.")
        case .colorLookup:
            return Encoded(blocks: nil, why: "ImageCrat's “\(s.lookName)” look has no Photoshop 3D LUT file to point to; the adjusted picture is stored as pixels.")
        case .replaceColor, .matchColor, .hdrToning:
            return Encoded(blocks: nil, why: "\(s.kind.displayName) is a destructive command in Photoshop; the adjusted picture is stored as pixels.")
        case .colorWB, .clarity, .dehaze, .grain, .light:
            return Encoded(blocks: nil, why: "\(s.kind.displayName) is a Camera Raw setting with no Photoshop adjustment layer; the adjusted picture is stored as pixels.")
        }
    }

    package static func rgb(_ c: RGBA) -> PSDDescriptorValue {
        .object(PSDDescriptor(classID: "RGBC", [("Rd  ", .double(clamp(fin(c.r), 0, 1) * 255)), ("Grn ", .double(clamp(fin(c.g), 0, 1) * 255)), ("Bl  ", .double(clamp(fin(c.b), 0, 1) * 255))]))
    }

    /// 'levl': version 2, then 29 records (composite, red, green, blue, then unused channels).
    package static func levels(_ s: AdjustmentSettings) -> Data {
        var w = BinaryWriter()
        w.u16(2)
        for i in 0..<29 {
            let c = i < s.levels.count && i < 4 ? s.levels[i] : LevelsChannel()
            let inB = clamp(fin(c.inBlack), 0, 253), inW = clamp(fin(c.inWhite, 255), inB + 2, 255)
            w.u16(UInt16(inB.rounded())); w.u16(UInt16(inW.rounded()))
            w.u16(UInt16(clamp(fin(c.outBlack), 0, 255).rounded())); w.u16(UInt16(clamp(fin(c.outWhite, 255), 0, 255).rounded()))
            w.u16(UInt16((clamp(fin(c.gamma, 1), 0.1, 9.99) * 100).rounded()))
        }
        return w.data
    }

    /// 'curv': map flag 0, version 1 with a channel bit mask, the curves (output, input pairs), then the 'Crv '
    /// extension (version 4) that Photoshop also writes, listing each curve with its channel index.
    package static func curves(_ s: AdjustmentSettings) -> Data {
        var chans: [(Int, [(Int, Int)])] = []
        for ch in 0..<min(4, s.curves.count) {
            var pts: [(Int, Int)] = []
            for p in s.curves[ch].points.sorted(by: { $0.x < $1.x }) where p.x.isFinite && p.y.isFinite {
                let x = Int((clamp(Double(p.x), 0, 1) * 255).rounded()), y = Int((clamp(Double(p.y), 0, 1) * 255).rounded())
                if let last = pts.last, last.0 >= x { continue }   // Photoshop needs strictly increasing inputs
                pts.append((x, y))
            }
            if pts.count < 2 { pts = [(0, 0), (255, 255)] }
            if ch == 0 || !(pts.count == 2 && pts[0] == (0, 0) && pts[1] == (255, 255)) { chans.append((ch, Array(pts.prefix(16)))) }
        }
        var w = BinaryWriter()
        w.u8(0); w.u16(1)
        var mask: UInt32 = 0
        for (ch, _) in chans { mask |= 1 << UInt32(ch) }
        w.u32(mask)
        for (_, pts) in chans {
            w.u16(UInt16(pts.count))
            for (x, y) in pts { w.u16(UInt16(y)); w.u16(UInt16(x)) }
        }
        w.ascii("Crv "); w.u16(4); w.u32(UInt32(chans.count))
        for (ch, pts) in chans {
            w.u16(UInt16(ch)); w.u16(UInt16(pts.count))
            for (x, y) in pts { w.u16(UInt16(y)); w.u16(UInt16(x)) }
        }
        return w.data
    }

    /// 'hue2': version 2, colorize flag, colorize hue / saturation / lightness, master values, six colour ranges.
    package static func hueSaturation(_ s: AdjustmentSettings) -> Data {
        var w = BinaryWriter()
        w.u16(2); w.u8(s.colorize ? 1 : 0); w.u8(0)
        if s.colorize {
            // Photoshop: hue 0…360, saturation 0…100 (Lumen 0 = Photoshop's default 25)
            let h = fin(s.hue).truncatingRemainder(dividingBy: 360)
            w.i16(Int16(((h + 360).truncatingRemainder(dividingBy: 360)).rounded()) % 360)
            w.i16(i16((fin(s.hsSaturation) + 100) / 4, 0, 100)); w.i16(i16(s.lightness, -100, 100))
            w.i16(0); w.i16(0); w.i16(0)
        } else {
            w.i16(0); w.i16(25); w.i16(0)
            w.i16(i16(s.hue, -180, 180)); w.i16(i16(s.hsSaturation, -100, 100)); w.i16(i16(s.lightness, -100, 100))
        }
        for i in 0..<6 {
            let r = i < s.hsRanges.count ? s.hsRanges[i] : HueRange(range: HueRange.defaultRanges[i])
            let rv = r.range.count == 4 && r.range.allSatisfy(\.isFinite) ? r.range : HueRange.defaultRanges[i]
            for v in rv { w.i16(Int16(((v.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360).rounded()) % 360) }
            w.i16(i16(r.hue, -180, 180)); w.i16(i16(r.saturation, -100, 100)); w.i16(i16(r.lightness, -100, 100))
        }
        return w.data
    }

    /// 'mixr': version 1, monochrome flag, then per output channel red, green, blue, (black), constant.
    package static func mixer(_ mono: Bool, _ r: [Double], _ g: [Double], _ b: [Double]) -> Data {
        var w = BinaryWriter()
        w.u16(1); w.u16(mono ? 1 : 0)
        for row in [r, g, b, [0, 0, 0, 0]] {
            let v = row.count >= 4 ? row : [0, 0, 0, 0]
            w.i16(i16(v[0], -200, 200)); w.i16(i16(v[1], -200, 200)); w.i16(i16(v[2], -200, 200)); w.i16(0); w.i16(i16(v[3], -200, 200))
        }
        return w.data
    }

    /// 'grdm' version 1: reverse, dither, name, colour stops, transparency stops, then the gradient settings tail.
    package static func gradientMap(_ g: ColorGradient, reverse: Bool) -> Data {
        var w = BinaryWriter()
        w.u16(1); w.u8(reverse ? 1 : 0); w.u8(0)
        w.unicode(g.name)
        var stops = g.sortedStops.filter { $0.location.isFinite }
        if stops.isEmpty { stops = ColorGradient.twoColor(.black, .white).stops }
        stops = Array(stops.prefix(256))
        func loc(_ s: GradientStop) -> UInt32 { UInt32((clamp(s.location, 0, 1) * 4096).rounded()) }
        w.u16(UInt16(stops.count))
        for s in stops {
            w.u32(loc(s)); w.u32(50); w.u16(0)
            for v in [s.color.r, s.color.g, s.color.b] { w.u16(UInt16(clamp(fin(v), 0, 1) * 65535 + 0.5)) }
            w.u16(0); w.u16(0)
        }
        w.u16(UInt16(stops.count))
        for s in stops { w.u32(loc(s)); w.u32(50); w.u16(UInt16(clamp(fin(s.color.a, 1), 0, 1) * 255 + 0.5)) }
        w.u16(2); w.u16(4096); w.u16(32); w.u16(0); w.u32(0); w.u16(0); w.u16(0); w.u32(2048); w.u16(3)
        for _ in 0..<4 { w.u16(0) }
        for _ in 0..<4 { w.u16(0x8000) }
        w.u16(0)
        return w.data
    }
}
