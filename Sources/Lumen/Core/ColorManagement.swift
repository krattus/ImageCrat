import AppKit
import CoreImage
import SwiftUI
import ImageCratCore

/// ICC profiles and colour conversions (assign / convert / soft-proof / gamut warning / CMYK & Lab).
enum ColorProfiles {
    struct Entry: Identifiable, Hashable {
        let name: String
        let url: URL?            // ICC file
        let cgName: CFString?    // built-in CGColorSpace name
        var id: String { name }
        static func == (a: Entry, b: Entry) -> Bool { a.name == b.name }
        func hash(into h: inout Hasher) { h.combine(name) }
    }

    static let sRGBName = "sRGB IEC61966-2.1"
    static let cmykName = "Generic CMYK Profile"

    static let builtIn: [Entry] = [
        Entry(name: sRGBName, url: nil, cgName: CGColorSpace.sRGB),
        Entry(name: "Display P3", url: nil, cgName: CGColorSpace.displayP3),
        Entry(name: "Adobe RGB (1998)", url: nil, cgName: CGColorSpace.adobeRGB1998),
        Entry(name: "ProPhoto RGB", url: nil, cgName: CGColorSpace.rommrgb),
        Entry(name: "Rec. ITU-R BT.2020", url: nil, cgName: CGColorSpace.itur_2020),
        Entry(name: "Generic Gray Gamma 2.2", url: nil, cgName: CGColorSpace.genericGrayGamma2_2),
        Entry(name: cmykName, url: nil, cgName: CGColorSpace.genericCMYK),
    ]

    /// Built-in spaces plus every ICC profile installed on the system.
    static let all: [Entry] = {
        var out = builtIn
        let dirs = ["/System/Library/ColorSync/Profiles", "/Library/ColorSync/Profiles", NSHomeDirectory() + "/Library/ColorSync/Profiles"]
        var seen = Set(out.map(\.name))
        for dir in dirs {
            let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            for u in urls where ["icc", "icm"].contains(u.pathExtension.lowercased()) {
                guard let data = try? Data(contentsOf: u), let cs = CGColorSpace(iccData: data as CFData) else { continue }
                let n = (cs.name as String?).map { ($0 as NSString).lastPathComponent } ?? u.deletingPathExtension().lastPathComponent
                let name = u.deletingPathExtension().lastPathComponent.isEmpty ? n : u.deletingPathExtension().lastPathComponent
                if seen.insert(name).inserted { out.append(Entry(name: name, url: u, cgName: nil)) }
            }
        }
        return out
    }()

    static var rgbProfiles: [Entry] { all.filter { space($0)?.model == .rgb } }
    static var cmykProfiles: [Entry] { all.filter { space($0)?.model == .cmyk } }

    private static var spaceCache: [String: CGColorSpace] = [:]

    static func space(_ e: Entry) -> CGColorSpace? {
        if let c = spaceCache[e.name] { return c }
        var cs: CGColorSpace?
        if let n = e.cgName { cs = CGColorSpace(name: n) }
        else if let u = e.url, let d = try? Data(contentsOf: u) { cs = CGColorSpace(iccData: d as CFData) }
        if let cs { spaceCache[e.name] = cs }
        return cs
    }

    static func space(named name: String?) -> CGColorSpace {
        guard let name, !isSRGB(name), let e = all.first(where: { $0.name == name }), let cs = space(e) else { return sRGBSpace }
        return cs
    }

    static func isSRGB(_ name: String?) -> Bool { name == nil || name == sRGBName || name == (CGColorSpace.sRGB as String) }
}

enum RenderingIntent: String, Codable, CaseIterable, Identifiable {
    case perceptual = "Perceptual", relative = "Relative Colorimetric", saturation = "Saturation", absolute = "Absolute Colorimetric"
    var id: String { rawValue }
    var cg: CGColorRenderingIntent {
        switch self {
        case .perceptual: return .perceptual
        case .relative: return .relativeColorimetric
        case .saturation: return .saturation
        case .absolute: return .absoluteColorimetric
        }
    }
}

struct ProofSettings: Codable, Equatable {
    var profileName = ColorProfiles.cmykName
    var intent: RenderingIntent = .relative
    var gamutColor = RGBA(gray: 0.5)
}

enum ColorConvert {
    static let cubeSize = 32

    /// Grid image of every cube colour (width = n*n, height = n), sRGB.
    private static func gridImage(_ n: Int) -> CGImage? {
        let w = n * n
        var bytes = [UInt8](repeating: 255, count: w * n * 4)
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let x = b * n + r, y = g
            let i = (y * w + x) * 4
            bytes[i] = UInt8(r * 255 / (n - 1)); bytes[i + 1] = UInt8(g * 255 / (n - 1)); bytes[i + 2] = UInt8(b * 255 / (n - 1))
        } } }
        let data = Data(bytes)
        guard let prov = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: w, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGBSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Draws `img` into a context of colour space `cs` and returns the result.
    static func draw(_ img: CGImage, into cs: CGColorSpace, intent: CGColorRenderingIntent) -> CGImage? {
        let w = img.width, h = img.height
        let ctx: CGContext?
        switch cs.model {
        case .cmyk:
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        case .monochrome:
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        default:
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        guard let ctx else { return nil }
        ctx.setRenderingIntent(intent)
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static var cubeCache: [String: (Data, Data)] = [:]

    /// (round-trip cube, gamut-distance cube) for soft-proofing through `space`.
    static func proofCubes(_ space: CGColorSpace, key: String, intent: RenderingIntent) -> (Data, Data)? {
        let k = key + intent.rawValue
        if let c = cubeCache[k] { return c }
        let n = cubeSize
        guard let grid = gridImage(n), let there = draw(grid, into: space, intent: intent.cg),
              let back = draw(there, into: sRGBSpace, intent: intent.cg),
              let raw = back.dataProvider?.data as Data? else { return nil }
        let w = n * n
        let bpr = back.bytesPerRow
        var cube = [Float](repeating: 1, count: n * n * n * 4)
        var gamut = [Float](repeating: 0, count: n * n * n * 4)
        raw.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let b8 = p.bindMemory(to: UInt8.self)
            for b in 0..<n { for g in 0..<n { for r in 0..<n {
                let x = b * n + r, y = g
                let i = y * bpr + x * 4
                let rr = Float(b8[i]) / 255, gg = Float(b8[i + 1]) / 255, bb = Float(b8[i + 2]) / 255
                let ci = ((b * n + g) * n + r) * 4
                cube[ci] = rr; cube[ci + 1] = gg; cube[ci + 2] = bb; cube[ci + 3] = 1
                let r0 = Float(r) / Float(n - 1), g0 = Float(g) / Float(n - 1), b0 = Float(b) / Float(n - 1)
                let d = max(abs(rr - r0), abs(gg - g0), abs(bb - b0))
                let out: Float = d > 0.1 ? 1 : 0
                gamut[ci] = out; gamut[ci + 1] = out; gamut[ci + 2] = out; gamut[ci + 3] = 1
            } } }
        }
        let res = (cube.withUnsafeBufferPointer { Data(buffer: $0) }, gamut.withUnsafeBufferPointer { Data(buffer: $0) })
        cubeCache[k] = res
        return res
    }

    /// Soft-proof `img` (display-referred sRGB values) through a proof profile.
    static func softProof(_ img: CIImage, settings: ProofSettings) -> CIImage {
        let cs = ColorProfiles.space(named: settings.profileName)
        guard let (cube, _) = proofCubes(cs, key: settings.profileName, intent: settings.intent) else { return img }
        return img.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": cubeSize, "inputCubeData": cube, "inputColorSpace": sRGBSpace])
    }

    /// Overlays the gamut-warning colour on colours that do not survive the proof profile.
    static func gamutWarning(_ img: CIImage, settings: ProofSettings) -> CIImage {
        let cs = ColorProfiles.space(named: settings.profileName)
        guard let (_, g) = proofCubes(cs, key: settings.profileName, intent: settings.intent) else { return img }
        let mask = img.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": cubeSize, "inputCubeData": g, "inputColorSpace": sRGBSpace])
        return CIImage.color(settings.gamutColor, img.extent).masked(byGray: mask).composited(over: img)
    }

    /// Display transform for a document whose pixel values are in `profile` (Assign Profile).
    static func displayImage(_ img: CIImage, profile: String?) -> CIImage {
        guard !ColorProfiles.isSRGB(profile) else { return img }
        let cs = ColorProfiles.space(named: profile)
        guard cs.model == .rgb else { return img }
        return img.matchedFromWorkingSpace(to: sRGBSpace)?.matchedToWorkingSpace(from: cs) ?? img
    }

    /// Converts pixel values from colour space `from` to `to` (RGB, alpha kept).
    static func convert(_ buf: PixelBuffer, from: CGColorSpace, to: CGColorSpace, intent: RenderingIntent) -> PixelBuffer {
        guard buf.format == .rgba else { return buf }
        let src = buf.makeCGImage()
        guard let tagged = src.copy(colorSpace: from) else { return buf }
        // Unpremultiplied conversion to keep edges right: draw onto opaque context, then restore alpha.
        let w = buf.width, h = buf.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: to.model == .rgb ? to : sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return buf }
        ctx.setRenderingIntent(intent.cg)
        ctx.draw(tagged, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return buf }
        return PixelBuffer(cgImage: out.copy(colorSpace: sRGBSpace) ?? out)
    }

    /// Round-trips pixel values through `space` (e.g. RGB → CMYK → RGB when converting mode).
    static func roundTrip(_ buf: PixelBuffer, through space: CGColorSpace, key: String, intent: RenderingIntent) -> PixelBuffer {
        guard buf.format == .rgba, let (cube, _) = proofCubes(space, key: key, intent: intent) else { return buf }
        let img = buf.ciImage.unpremultiplyingAlpha()
            .applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": cubeSize, "inputCubeData": cube, "inputColorSpace": sRGBSpace])
            .premultiplyingAlpha()
        let sp = CanvasSpace(width: buf.width, height: buf.height)
        return RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: IRect(x: 0, y: 0, width: buf.width, height: buf.height), space: sp)
    }

    // MARK: Channel views for CMYK / Lab documents

    static let cmykChannelKernel = CIColorKernel(source: """
    kernel vec4 cmykCh(__sample s, float which) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(1.0);
        float k = 1.0 - max(max(c.r, c.g), c.b);
        float d = max(1.0 - k, 0.0001);
        float cy = (1.0 - c.r - k) / d, ma = (1.0 - c.g - k) / d, ye = (1.0 - c.b - k) / d;
        float v = which < 0.5 ? cy : (which < 1.5 ? ma : (which < 2.5 ? ye : k));
        v = 1.0 - clamp(v, 0.0, 1.0);
        return vec4(v, v, v, 1.0);
    }
    """)

    static let labChannelKernel = CIColorKernel(source: """
    float lin(float c) { return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4); }
    float fl(float t) { return t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0; }
    kernel vec4 labCh(__sample s, float which) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(1.0);
        vec3 l = vec3(lin(c.r), lin(c.g), lin(c.b));
        float X = (0.4124 * l.r + 0.3576 * l.g + 0.1805 * l.b) / 0.95047;
        float Y = 0.2126 * l.r + 0.7152 * l.g + 0.0722 * l.b;
        float Z = (0.0193 * l.r + 0.1192 * l.g + 0.9505 * l.b) / 1.08883;
        float fx = fl(X), fy = fl(Y), fz = fl(Z);
        float L = 116.0 * fy - 16.0, A = 500.0 * (fx - fy), B = 200.0 * (fy - fz);
        float v = which < 0.5 ? L / 100.0 : (which < 1.5 ? A / 255.0 + 0.5 : B / 255.0 + 0.5);
        return vec4(v, v, v, 1.0);
    }
    """)

    /// Lab values (L 0…100, a, b) of an sRGB colour.
    static func lab(_ c: RGBA) -> (Double, Double, Double) {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let X = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let Y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let Z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        return (116 * f(Y) - 16, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z)))
    }

    /// CMYK percentages of an sRGB colour through the proof profile.
    static func cmyk(_ c: RGBA, profile: String = ColorProfiles.cmykName) -> (Double, Double, Double, Double) {
        let cs = ColorProfiles.space(named: profile)
        guard cs.model == .cmyk, let src = CGColor(colorSpace: sRGBSpace, components: [c.r, c.g, c.b, 1]).map({ $0 }),
              let conv = src.converted(to: cs, intent: .relativeColorimetric, options: nil), let comps = conv.components, comps.count >= 4 else {
            let k = 1 - max(c.r, c.g, c.b), d = max(0.0001, 1 - k)
            return ((1 - c.r - k) / d, (1 - c.g - k) / d, (1 - c.b - k) / d, k)
        }
        return (Double(comps[0]), Double(comps[1]), Double(comps[2]), Double(comps[3]))
    }
}

// MARK: - Document actions

extension AppActions {
    /// Applies `f` to every raster buffer in the document (layers, smart sources are left as they are).
    static func mapAllRasters(_ st: inout DocumentState, _ f: (PixelBuffer) -> PixelBuffer) {
        func mapLayers(_ ls: [Layer]) -> [Layer] {
            ls.map { l in
                var x = l
                switch l.content {
                case .raster(var r): r.buffer = f(r.buffer); x.content = .raster(r)
                case .group(var g): g.children = mapLayers(g.children); x.content = .group(g)
                default: break
                }
                return x
            }
        }
        st.layers = mapLayers(st.layers)
    }

    static func convertMode(_ m: ColorMode) {
        if ColorModes.intercept(m) { return }   // Bitmap / Duotone / Indexed / Multichannel (Imaging module)
        guard let d = doc, d.state.colorMode != m else { return }
        ActionRecorder.record(.colorMode(m))
        switch m {
        case .grayscale:
            convertToGrayscale(commit: false)   // one history step for the mode change
            d.state.colorMode = .grayscale
            d.commit("Grayscale")
            return
        case .cmyk:
            let cs = ColorProfiles.space(named: app.proof.profileName)
            var st = d.state
            mapAllRasters(&st) { ColorConvert.roundTrip($0, through: cs, key: app.proof.profileName, intent: app.proof.intent) }
            st.colorMode = .cmyk
            d.state = st
            d.commit("Convert to CMYK")
        case .lab, .rgb:
            d.state.colorMode = m
            d.commit("Convert to \(m.short)")
        case .bitmap, .duotone, .indexed, .multichannel:
            return
        }
        Compositor.shared.clearCaches()
        d.setNeedsRender()
    }

    static func setBitDepth(_ b: BitDepth) {
        guard let d = doc, d.state.bitDepth != b else { return }
        d.state.bitDepth = b
        d.commit("\(b.rawValue) Bits/Channel")
    }

    static func assignProfile(_ name: String?) {
        guard let d = doc else { return }
        d.state.profileName = ColorProfiles.isSRGB(name) ? ColorProfiles.sRGBName : name!
        d.commit("Assign Profile")
        d.setNeedsRender()
    }

    static func convertToProfile(_ name: String, intent: RenderingIntent) {
        guard let d = doc else { return }
        let from = ColorProfiles.space(named: d.state.profileName)
        let to = ColorProfiles.space(named: name)
        guard to.model == .rgb else {
            if to.model == .cmyk { app.proof.profileName = name; convertMode(.cmyk) }
            return
        }
        var st = d.state
        mapAllRasters(&st) { ColorConvert.convert($0, from: from, to: to, intent: intent) }
        st.profileName = ColorProfiles.isSRGB(name) ? ColorProfiles.sRGBName : name
        d.state = st
        d.commit("Convert to Profile")
        Compositor.shared.clearCaches()
        d.setNeedsRender()
    }
}

// MARK: - Dialogs

struct ColorProfileDialog: View {
    let convert: Bool
    @State private var profile = ColorProfiles.isSRGB(AppActions.doc?.state.profileName) ? ColorProfiles.sRGBName : AppActions.doc!.state.profileName
    @State private var intent: RenderingIntent = .relative
    @State private var dontManage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr(convert ? "Convert to Profile" : "Assign Profile")).font(.system(size: 13, weight: .semibold))
            Text(tr("Current: " + (ColorProfiles.isSRGB(AppActions.doc?.state.profileName) ? ColorProfiles.sRGBName : AppActions.doc!.state.profileName))).foregroundStyle(Theme.textDim)
            if !convert {
                Toggle2(label: "Don't Color Manage This Document (sRGB)", on: $dontManage)
            }
            Picker("Profile", selection: $profile) {
                ForEach(convert ? ColorProfiles.all : ColorProfiles.rgbProfiles) { e in Text(tr(e.name)).tag(e.name) }
            }
            .disabled(dontManage)
            if convert {
                Picker("Intent", selection: $intent) { ForEach(RenderingIntent.allCases) { Text(tr($0.rawValue)).tag($0) } }
            }
            Text(tr(convert ? "Pixel values are converted so colours look the same in the new profile." : "Pixel values are kept; their colour appearance changes."))
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            HStack {
                Spacer()
                Button("Cancel") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("OK") {
                    AppModel.shared.dialog = nil
                    if convert { AppActions.convertToProfile(profile, intent: intent) } else { AppActions.assignProfile(dontManage ? nil : profile) }
                }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 420)
    }
}

struct ProofSetupDialog: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Customize Proof Condition").font(.system(size: 13, weight: .semibold))
            Picker("Device to Simulate", selection: $app.proof.profileName) {
                ForEach(ColorProfiles.all) { e in Text(tr(e.name)).tag(e.name) }
            }
            Picker("Rendering Intent", selection: $app.proof.intent) { ForEach(RenderingIntent.allCases) { Text(tr($0.rawValue)).tag($0) } }
            HStack {
                Text("Gamut Warning Color").foregroundStyle(Theme.textDim)
                ColorWell(color: $app.proof.gamutColor)
            }
            HStack {
                Toggle2(label: "Preview (Proof Colors)", on: Binding(get: { app.activeDocument?.proofColors ?? false }, set: { app.activeDocument?.proofColors = $0; app.activeDocument?.setNeedsRender() }))
                Spacer()
                Button("OK") { app.dialog = nil; app.activeDocument?.setNeedsRender() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 420)
        .onChange(of: app.proof) { _, _ in app.activeDocument?.setNeedsRender() }
    }
}
