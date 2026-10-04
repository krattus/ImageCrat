import Foundation
import Observation
import ImageCratCore

/// A reusable recipe (built in, or a `.icrecipe` file in the support folder).
struct RecipePreset: Identifiable {
    var id: String
    var name: String
    var blurb: String = ""
    var graph: RecipeGraph
    var builtIn = false
    var url: URL? = nil
    /// True when the recipe reads the layers below (false: pure generator).
    var usesSource: Bool { graph.nodes.contains { $0.type == "in.source" } }
}

/// On-disk format of a `.icrecipe` file (JSON; `.lumenrecipe` from before the rename is the same format).
struct RecipeFile: Codable {
    var lumenRecipe = 1
    var name: String
    var description: String = ""
    var graph: RecipeGraph

    init(name: String, description: String = "", graph: RecipeGraph) { self.name = name; self.description = description; self.graph = graph }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lumenRecipe = (try? c.decodeIfPresent(Int.self, forKey: .lumenRecipe)) ?? 1
        graph = try c.decode(RecipeGraph.self, forKey: .graph)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? graph.name
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? ""
    }
}

/// User recipe library: `~/Library/Application Support/ImageCrat/Recipes/*.icrecipe` (or `$LUMEN_SUPPORT_DIR/Recipes`).
@Observable
final class RecipePresetStore {
    static let shared = RecipePresetStore()
    static let fileExtension = Brand.recipeExtension
    /// Extensions read from the library folder and accepted by Import: `.icrecipe` and the older `.lumenrecipe`.
    static let readableExtensions = Brand.recipeExtensions

    private(set) var user: [RecipePreset] = []
    /// nil = in-memory only (self tests never touch the real support folder).
    @ObservationIgnored private(set) var directory: URL?
    @ObservationIgnored private var loaded = false

    static var isSelfTest: Bool {
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--perftest") || ProcessInfo.processInfo.environment["LUMEN_NODES_SELFTEST"] != nil
    }

    static var defaultDirectory: URL? {
        if let o = ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"], !o.isEmpty { return URL(fileURLWithPath: o).appendingPathComponent("Recipes") }
        if isSelfTest { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(Brand.supportFolderName).appendingPathComponent("Recipes")
    }

    init(directory: URL? = RecipePresetStore.defaultDirectory) { self.directory = directory }

    /// Points the store at another folder (tests use a temp dir) and reloads.
    func configure(directory: URL?) {
        self.directory = directory
        loaded = false
        user = []
        loadIfNeeded()
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let dir = directory, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        var out: [RecipePreset] = []
        for u in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) where Self.readableExtensions.contains(u.pathExtension.lowercased()) {
            if let p = Self.read(u) { out.append(p) }
        }
        user = out
    }

    var all: [RecipePreset] { loadIfNeeded(); return RecipePresets.builtIn + user }

    static func read(_ url: URL) -> RecipePreset? {
        guard let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(RecipeFile.self, from: data) else { return nil }
        var g = f.graph
        g.name = f.name
        return RecipePreset(id: "user:" + url.lastPathComponent, name: f.name, blurb: f.description, graph: g, builtIn: false, url: url)
    }

    static func data(name: String, description: String = "", graph: RecipeGraph) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var g = graph
        g.name = name
        g.solo = nil
        return try enc.encode(RecipeFile(name: name, description: description, graph: g))
    }

    /// Saves (or overwrites) a user recipe. Without a directory the preset is kept in memory only.
    @discardableResult
    func save(name: String, description: String = "", graph: RecipeGraph) throws -> RecipePreset {
        loadIfNeeded()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Recipe" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = clean.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" ? $0 : "_" }
        let fileName = String(safe) + "." + Self.fileExtension
        var g = graph
        g.name = clean
        g.solo = nil
        var preset = RecipePreset(id: "user:" + fileName, name: clean, blurb: description, graph: g, builtIn: false, url: nil)
        if let dir = directory {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(fileName)
            try Self.data(name: clean, description: description, graph: g).write(to: url, options: .atomic)
            preset.url = url
            // overwriting a recipe saved before the rename: its .lumenrecipe file is replaced by the .icrecipe one
            let legacyName = String(safe) + "." + Brand.Legacy.recipeExtension
            let legacy = dir.appendingPathComponent(legacyName)
            if FileManager.default.fileExists(atPath: legacy.path) { try? FileManager.default.removeItem(at: legacy) }
            user.removeAll { $0.id == "user:" + legacyName }
        }
        user.removeAll { $0.id == preset.id }
        RecipeThumbnails.shared.invalidate(preset.id)
        user.append(preset)
        user.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return preset
    }

    func delete(_ p: RecipePreset) {
        if let u = p.url { try? FileManager.default.removeItem(at: u) }
        user.removeAll { $0.id == p.id }
    }

    /// Copies a `.icrecipe` (or older `.lumenrecipe`) from anywhere into the library.
    @discardableResult
    func importFile(_ url: URL) throws -> RecipePreset {
        guard let p = Self.read(url) else { throw DocumentIOError.unreadable }
        return try save(name: p.name, description: p.blurb, graph: p.graph)
    }
}

/// The recipes that ship with the app.
enum RecipePresets {
    static let builtIn: [RecipePreset] = [
        duotonePoster, halftonePrint, glitch, filmLook, frostedGlass, neonEdges, paperInk, sketch, tiltShift, marble, risograph, vintagePhoto, woodPlanks,
    ]

    static func preset(named n: String) -> RecipePreset? { builtIn.first { $0.name == n } }

    private static func make(_ name: String, _ blurb: String, _ build: (inout RecipeBuilder) -> Void) -> RecipePreset {
        var b = RecipeBuilder(name)
        build(&b)
        b.finish()
        return RecipePreset(id: "builtin:" + name, name: name, blurb: blurb, graph: b.graph, builtIn: true)
    }

    private static func mode(_ m: BlendMode) -> Double { Double(BlendMode.layerModes.firstIndex(of: m) ?? 0) }
    private static func grad(_ name: String, _ stops: [(Double, String)]) -> ColorGradient { TextureCatalog.ramp(name, stops) }

    static let duotonePoster = make("Duotone Poster", "High-contrast two-ink poster look with a hint of grain.") { b in
        let src = b.add("in.source", col: 0)
        let bw = b.add("adj.blackWhite", col: 1)
        let con = b.add("adj.brightnessContrast", col: 2, ["contrast": 45])
        let post = b.add("adj.posterize", col: 3, ["posterizeLevels": 6])
        let map = b.add("util.gradientMap", col: 4, gradient: ("gradient", grad("Duotone", [(0, "1B1F5A"), (0.55, "FF6B5E"), (1, "FFF1D6")])))
        let grain = b.add("gen.filmgrain", col: 4, row: 1, ["stock": 1, "amount": 0.5, "scale": 5])
        let mix = b.add("comp.blend", col: 5, ["mode": mode(.overlay), "opacity": 35])
        let out = b.add("out.output", col: 6)
        b.wire(src, "Image", bw); b.wire(bw, "Image", con); b.wire(con, "Image", post); b.wire(post, "Image", map)
        b.wire(map, "Image", mix, "Base"); b.wire(grain, "Image", mix, "Blend"); b.wire(mix, "Image", out)
        b.expose(con, "contrast", "Contrast"); b.expose(post, "posterizeLevels", "Levels"); b.expose(map, "gradient", "Inks"); b.expose(mix, "opacity", "Grain")
        b.frame("Tone", around: [bw, con, post])
    }

    static let halftonePrint = make("Halftone Print", "Newsprint dots: a rotated dot screen thresholded against the image.") { b in
        let src = b.add("in.source", col: 0)
        let bw = b.add("adj.blackWhite", col: 1)
        let screen = b.add("gen.dots", col: 1, row: 1, ["shape": 3, "scale": 9, "rotation": 45], title: "Dot Screen")
        let cmp = b.add("imath.compare", col: 2, ["op": 1, "soft": 0.06])
        let paper = b.add("in.solid", col: 2, row: 1, colors: ["color": RGBA(hex: "F4EFE4")!], title: "Paper")
        let ink = b.add("in.solid", col: 2, row: 2, colors: ["color": RGBA(hex: "1A1A2E")!], title: "Ink")
        let mix = b.add("comp.blend", col: 3)
        let out = b.add("out.output", col: 4)
        b.wire(src, "Image", bw); b.wire(bw, "Image", cmp, "A"); b.wire(screen, "Image", cmp, "B")
        b.wire(paper, "Image", mix, "Base"); b.wire(ink, "Image", mix, "Blend"); b.wire(cmp, "Mask", mix, "Mask"); b.wire(mix, "Image", out)
        b.expose(screen, "scale", "Dot Size"); b.expose(screen, "rotation", "Screen Angle"); b.expose(ink, "color", "Ink"); b.expose(paper, "color", "Paper")
    }

    static let glitch = make("Glitch / RGB Split", "Channel misregistration, block displacement and scanlines.") { b in
        let src = b.add("in.source", col: 0)
        let amt = b.add("const.number", col: 0, row: 1, ["value": 14], title: "Split Amount")
        let neg = b.add("math.op", col: 1, row: 2, ["op": 2, "b": -1], title: "× −1")
        let split = b.add("chan.split", col: 1)
        let tr = b.add("xf.translate", col: 2, ["edge": 1], title: "Shift Red")
        let tb = b.add("xf.translate", col: 2, row: 1, ["edge": 1], title: "Shift Blue")
        let merge = b.add("chan.merge", col: 3)
        let blocks = b.add("gen.glitch", col: 3, row: 1, ["style": 2, "rows": 22, "density": 0.35, "scale": 420])
        let disp = b.add("xf.displace", col: 4, ["sx": 70, "sy": 0])
        let lines = b.add("gen.scanlines", col: 4, row: 1, ["scale": 3, "soft": 0.35])
        let mix = b.add("comp.blend", col: 5, ["mode": mode(.multiply), "opacity": 35])
        let out = b.add("out.output", col: 6)
        b.wire(src, "Image", split); b.wire(amt, "Value", tr, "p:dx"); b.wire(amt, "Value", neg, "p:a"); b.wire(neg, "Value", tb, "p:dx")
        b.wire(split, "R", tr); b.wire(split, "B", tb)
        b.wire(tr, "Image", merge, "R"); b.wire(split, "G", merge, "G"); b.wire(tb, "Image", merge, "B"); b.wire(split, "A", merge, "A")
        b.wire(merge, "Image", disp); b.wire(blocks, "Image", disp, "Map")
        b.wire(disp, "Image", mix, "Base"); b.wire(lines, "Image", mix, "Blend"); b.wire(mix, "Image", out)
        b.expose(amt, "value", "RGB Split"); b.expose(disp, "sx", "Block Shift"); b.expose(blocks, "seed", "Glitch Seed"); b.expose(blocks, "density", "Glitch Density")
        b.expose(mix, "opacity", "Scanlines")
        b.frame("RGB split", around: [amt, neg, split, tr, tb, merge])
    }

    static let filmLook = make("Film Look", "Faded grade, red halation around highlights, grain and a soft vignette.") { b in
        let src = b.add("in.source", col: 0)
        let lut = b.add("util.lut", col: 1, ["look": 3, "amount": 0.6], title: "Grade")
        let lum = b.add("mask.fromImage", col: 1, row: 2)
        let thr = b.add("mask.threshold", col: 2, row: 2, ["level": 0.72, "soft": 0.25])
        let hi = b.add("comp.mask", col: 3, row: 2, title: "Highlights")
        let blur = b.add("filter.gaussianBlur", col: 4, row: 2, ["radius": 26], title: "Halation Blur")
        let tint = b.add("util.gradientMap", col: 5, row: 2, gradient: ("gradient", grad("Halation", [(0, "000000"), (1, "FF5A36")])))
        let halo = b.add("comp.blend", col: 6, ["mode": mode(.screen), "opacity": 60], title: "Add Halation")
        let grain = b.add("gen.filmgrain", col: 6, row: 1, ["stock": 1, "amount": 0.55, "scale": 5])
        let gmix = b.add("comp.blend", col: 7, ["mode": mode(.overlay), "opacity": 45], title: "Add Grain")
        let vig = b.add("filter.vignette", col: 8, ["intensity": 0.5])
        let out = b.add("out.output", col: 9)
        b.wire(src, "Image", lut); b.wire(src, "Image", lum); b.wire(lum, "Mask", thr, "Mask"); b.wire(src, "Image", hi); b.wire(thr, "Mask", hi, "Mask")
        b.wire(hi, "Image", blur); b.wire(blur, "Image", tint); b.wire(lut, "Image", halo, "Base"); b.wire(tint, "Image", halo, "Blend")
        b.wire(halo, "Image", gmix, "Base"); b.wire(grain, "Image", gmix, "Blend"); b.wire(gmix, "Image", vig); b.wire(vig, "Image", out)
        b.expose(lut, "amount", "Fade"); b.expose(blur, "radius", "Halation Size"); b.expose(halo, "opacity", "Halation"); b.expose(gmix, "opacity", "Grain"); b.expose(vig, "intensity", "Vignette")
        b.frame("Halation", around: [lum, thr, hi, blur, tint], color: RGBA(hex: "B84A4A")!)
    }

    static let frostedGlass = make("Frosted Glass", "Blurs and scatters the layers below like a frosted pane.") { b in
        let src = b.add("in.source", col: 0)
        let blur = b.add("filter.gaussianBlur", col: 1, ["radius": 14])
        let frost = b.add("const.number", col: 1, row: 1, ["value": 9], title: "Frost")
        let noise = b.add("gen.filmgrain", col: 1, row: 2, ["stock": 4, "amount": 1, "chroma": 1, "scale": 4], title: "Scatter Map")
        let disp = b.add("xf.displace", col: 2)
        let white = b.add("in.solid", col: 2, row: 1, colors: ["color": .white], title: "Tint")
        let tint = b.add("comp.blend", col: 3, ["opacity": 14])
        let grain = b.add("gen.filmgrain", col: 3, row: 1, ["stock": 0, "amount": 0.4, "scale": 4])
        let gmix = b.add("comp.blend", col: 4, ["mode": mode(.softLight), "opacity": 50])
        let out = b.add("out.output", col: 5)
        b.wire(src, "Image", blur); b.wire(blur, "Image", disp); b.wire(noise, "Image", disp, "Map")
        b.wire(frost, "Value", disp, "p:sx"); b.wire(frost, "Value", disp, "p:sy")
        b.wire(disp, "Image", tint, "Base"); b.wire(white, "Image", tint, "Blend"); b.wire(tint, "Image", gmix, "Base"); b.wire(grain, "Image", gmix, "Blend"); b.wire(gmix, "Image", out)
        b.expose(blur, "radius", "Blur"); b.expose(frost, "value", "Frost"); b.expose(tint, "opacity", "Tint"); b.expose(white, "color", "Tint Color")
    }

    static let neonEdges = make("Neon Glow Edges", "Finds edges and lights them up with a two-tone neon glow on black.") { b in
        let src = b.add("in.source", col: 0)
        let edge = b.add("util.edge", col: 1, ["strength": 3.2, "radius": 1])
        let col = b.add("util.gradientMap", col: 2, gradient: ("gradient", grad("Neon", [(0, "000000"), (0.35, "FF2BD6"), (0.75, "2BF0FF"), (1, "FFFFFF")])))
        let g1 = b.add("filter.gaussianBlur", col: 3, row: 1, ["radius": 5], title: "Tight Glow")
        let g2 = b.add("filter.gaussianBlur", col: 3, row: 2, ["radius": 24], title: "Wide Glow")
        let black = b.add("in.solid", col: 3, colors: ["color": .black])
        let m1 = b.add("comp.blend", col: 4, ["mode": mode(.screen)])
        let m2 = b.add("comp.blend", col: 5, ["mode": mode(.screen)])
        let m3 = b.add("comp.blend", col: 6, ["mode": mode(.screen)])
        let out = b.add("out.output", col: 7)
        b.wire(src, "Image", edge); b.wire(edge, "Edges", col); b.wire(col, "Image", g1); b.wire(col, "Image", g2)
        b.wire(black, "Image", m1, "Base"); b.wire(g2, "Image", m1, "Blend"); b.wire(m1, "Image", m2, "Base"); b.wire(g1, "Image", m2, "Blend")
        b.wire(m2, "Image", m3, "Base"); b.wire(col, "Image", m3, "Blend"); b.wire(m3, "Image", out)
        b.expose(edge, "strength", "Edge Strength"); b.expose(g2, "radius", "Glow Size"); b.expose(col, "gradient", "Neon Colors")
        b.frame("Glow", around: [g1, g2, m1, m2, m3], color: RGBA(hex: "8A5AB8")!)
    }

    static let paperInk = make("Paper + Ink", "Posterized ink with wobbly edges printed on fibrous paper.") { b in
        let src = b.add("in.source", col: 0)
        let post = b.add("adj.posterize", col: 1, ["posterizeLevels": 4])
        let wob = b.add("gen.fbm", col: 1, row: 1, ["scale": 14, "octaves": 3], title: "Wobble Map")
        let disp = b.add("xf.displace", col: 2, ["sx": 4, "sy": 4])
        let paper = b.add("gen.paper", col: 2, row: 1, ["scale": 110, "fibres": 0.8])
        let mul = b.add("comp.blend", col: 3, ["mode": mode(.multiply), "opacity": 100], title: "Print on Paper")
        let grain = b.add("gen.filmgrain", col: 3, row: 1, ["stock": 0, "amount": 0.4, "scale": 4])
        let gmix = b.add("comp.blend", col: 4, ["mode": mode(.softLight), "opacity": 35])
        let out = b.add("out.output", col: 5)
        b.wire(src, "Image", post); b.wire(post, "Image", disp); b.wire(wob, "Image", disp, "Map")
        b.wire(paper, "Image", mul, "Base"); b.wire(disp, "Image", mul, "Blend"); b.wire(mul, "Image", gmix, "Base"); b.wire(grain, "Image", gmix, "Blend"); b.wire(gmix, "Image", out)
        b.expose(post, "posterizeLevels", "Ink Levels"); b.expose(disp, "sx", "Ink Wobble"); b.expose(paper, "fibres", "Paper Fibres"); b.expose(gmix, "opacity", "Grain")
    }

    static let sketch = make("Sketch / Line Art", "Pencil lines from a colour-dodge of the blurred negative, with hatching in the shadows.") { b in
        let src = b.add("in.source", col: 0)
        let gray = b.add("adj.desaturate", col: 1)
        let inv = b.add("imath.invert", col: 2, row: 1)
        let blur = b.add("filter.gaussianBlur", col: 3, row: 1, ["radius": 7], title: "Line Weight")
        let dodge = b.add("comp.blend", col: 4, ["mode": mode(.colorDodge)], title: "Color Dodge")
        let lev = b.add("adj.levels", col: 5, ["inBlack": 110, "levelsGamma": 0.6])
        let hatch = b.add("gen.stripes", col: 4, row: 3, ["scale": 5, "rotation": 45, "duty": 0.4, "soft": 0.2, "invert": 1], title: "Hatching")
        let dark = b.add("mask.threshold", col: 3, row: 3, ["level": 0.55, "soft": 0.3], title: "Shadows")
        let hmix = b.add("comp.blend", col: 6, ["mode": mode(.multiply), "opacity": 45], title: "Hatch Shadows")
        let paper = b.add("gen.paper", col: 6, row: 1, ["scale": 100])
        let pmix = b.add("comp.blend", col: 7, ["mode": mode(.multiply)])
        let out = b.add("out.output", col: 8)
        b.wire(src, "Image", gray); b.wire(gray, "Image", inv); b.wire(inv, "Image", blur)
        b.wire(gray, "Image", dodge, "Base"); b.wire(blur, "Image", dodge, "Blend"); b.wire(dodge, "Image", lev)
        b.wire(inv, "Image", dark, "Mask"); b.wire(lev, "Image", hmix, "Base"); b.wire(hatch, "Image", hmix, "Blend"); b.wire(dark, "Mask", hmix, "Mask")
        b.wire(hmix, "Image", pmix, "Base"); b.wire(paper, "Image", pmix, "Blend"); b.wire(pmix, "Image", out)
        b.expose(blur, "radius", "Line Weight"); b.expose(lev, "inBlack", "Line Darkness"); b.expose(hmix, "opacity", "Hatching"); b.expose(hatch, "scale", "Hatch Spacing")
        b.frame("Hatching", around: [hatch, dark])
    }

    static let tiltShift = make("Tilt-Shift Miniature", "Keeps a band in focus, blurs the rest and boosts colour for a toy-model look.") { b in
        let src = b.add("in.source", col: 0)
        let band = b.add("in.gradient", col: 0, row: 1, ["type": 3, "angle": 90, "scale": 0.55], title: "Focus Band")
        let blur = b.add("util.blurByMask", col: 1, ["radius": 22])
        let vib = b.add("adj.vibrance", col: 2, ["vibrance": 45, "saturation": 18])
        let con = b.add("adj.brightnessContrast", col: 3, ["contrast": 22])
        let out = b.add("out.output", col: 4)
        b.wire(src, "Image", blur); b.wire(band, "Image", blur, "Mask"); b.wire(blur, "Image", vib); b.wire(vib, "Image", con); b.wire(con, "Image", out)
        b.expose(band, "center", "Focus Position"); b.expose(band, "scale", "Focus Width"); b.expose(blur, "radius", "Blur"); b.expose(vib, "saturation", "Saturation")
    }

    static let marble = make("Marble Material", "Procedural marble lit from its own height map (no input needed).") { b in
        let tex = b.add("gen.marble", col: 0, ["scale": 320, "seed": 4])
        let nrm = b.add("util.normal", col: 1, row: 1, ["strength": 0.9])
        let ao = b.add("util.ao", col: 1, row: 2, ["radius": 6, "strength": 0.4])
        let lit = b.add("util.light", col: 2, ["angle": 130, "elevation": 50, "specular": 0.5, "shininess": 60, "ambient": 0.35, "diffuse": 0.9])
        let mul = b.add("imath.op", col: 3, ["op": 2], title: "× Occlusion")
        let out = b.add("out.output", col: 4)
        b.wire(tex, "Image", nrm, "Height"); b.wire(tex, "Image", ao, "Height"); b.wire(nrm, "Normal", lit, "Normal"); b.wire(tex, "Image", lit, "Albedo")
        b.wire(lit, "Image", mul, "A"); b.wire(ao, "AO", mul, "B"); b.wire(mul, "Image", out)
        b.expose(tex, "scale", "Scale"); b.expose(tex, "seed", "Seed"); b.expose(tex, "turb", "Veining"); b.expose(tex, "ramp", "Stone Colors")
        b.expose(nrm, "strength", "Relief"); b.expose(lit, "angle", "Light Angle")
    }

    static let risograph = make("Risograph", "Two misregistered spot inks, dithered, on warm paper.") { b in
        let src = b.add("in.source", col: 0)
        let bw = b.add("adj.blackWhite", col: 1)
        let d1 = b.add("util.dither", col: 2, ["levels": 2, "pattern": 1, "mono": 1, "cell": 2], title: "Ink 1 Screen")
        let dk = b.add("adj.brightnessContrast", col: 2, row: 1, ["brightness": 70, "contrast": 25])
        let d2 = b.add("util.dither", col: 3, row: 1, ["levels": 2, "pattern": 2, "mono": 1, "cell": 2], title: "Ink 2 Screen")
        let i1 = b.add("imath.invert", col: 3)
        let i2 = b.add("imath.invert", col: 4, row: 1)
        let off = b.add("xf.translate", col: 5, row: 1, ["dx": 6, "dy": 4, "edge": 1], title: "Misregistration")
        let paper = b.add("in.solid", col: 4, row: 2, colors: ["color": RGBA(hex: "F3EDE0")!], title: "Paper")
        let ink1 = b.add("in.solid", col: 4, colors: ["color": RGBA(hex: "FF48B0")!], title: "Ink 1")
        let ink2 = b.add("in.solid", col: 5, row: 2, colors: ["color": RGBA(hex: "0078BF")!], title: "Ink 2")
        let m1 = b.add("comp.blend", col: 6, ["mode": mode(.multiply)])
        let m2 = b.add("comp.blend", col: 7, ["mode": mode(.multiply)])
        let grain = b.add("gen.filmgrain", col: 7, row: 1, ["stock": 2, "amount": 0.45, "scale": 4])
        let gmix = b.add("comp.blend", col: 8, ["mode": mode(.softLight), "opacity": 35])
        let out = b.add("out.output", col: 9)
        b.wire(src, "Image", bw); b.wire(bw, "Image", d1); b.wire(bw, "Image", dk); b.wire(dk, "Image", d2); b.wire(d1, "Image", i1); b.wire(d2, "Image", i2); b.wire(i2, "Image", off)
        b.wire(paper, "Image", m1, "Base"); b.wire(ink1, "Image", m1, "Blend"); b.wire(i1, "Image", m1, "Mask")
        b.wire(m1, "Image", m2, "Base"); b.wire(ink2, "Image", m2, "Blend"); b.wire(off, "Image", m2, "Mask")
        b.wire(m2, "Image", gmix, "Base"); b.wire(grain, "Image", gmix, "Blend"); b.wire(gmix, "Image", out)
        b.expose(ink1, "color", "Ink 1"); b.expose(ink2, "color", "Ink 2"); b.expose(paper, "color", "Paper"); b.expose(off, "dx", "Misregistration"); b.expose(d1, "cell", "Dot Size")
        b.frame("Ink 2 (shadows)", around: [dk, d2, i2, off], color: RGBA(hex: "4A76B8")!)
    }

    static let vintagePhoto = make("Vintage Photo", "Sepia, faded blacks, vignette, dust, scratches and a light leak.") { b in
        let src = b.add("in.source", col: 0)
        let sep = b.add("filter.sepia", col: 1, ["intensity": 0.7])
        let lut = b.add("util.lut", col: 2, ["look": 3, "amount": 0.5], title: "Fade")
        let vig = b.add("filter.vignette", col: 3, ["intensity": 0.8])
        let dust = b.add("gen.dust", col: 3, row: 1, ["scale": 420, "scratches": 0.6])
        let dmix = b.add("comp.blend", col: 4, ["mode": mode(.screen), "opacity": 60], title: "Dust")
        let leak = b.add("gen.lightleak", col: 4, row: 1, ["seed": 5])
        let lmix = b.add("comp.blend", col: 5, ["mode": mode(.screen), "opacity": 55], title: "Light Leak")
        let grain = b.add("gen.filmgrain", col: 5, row: 1, ["stock": 2, "amount": 0.55, "scale": 5])
        let gmix = b.add("comp.blend", col: 6, ["mode": mode(.overlay), "opacity": 40], title: "Grain")
        let soft = b.add("filter.gaussianBlur", col: 7, ["radius": 0.6])
        let out = b.add("out.output", col: 8)
        b.wire(src, "Image", sep); b.wire(sep, "Image", lut); b.wire(lut, "Image", vig)
        b.wire(vig, "Image", dmix, "Base"); b.wire(dust, "Image", dmix, "Blend"); b.wire(dmix, "Image", lmix, "Base"); b.wire(leak, "Image", lmix, "Blend")
        b.wire(lmix, "Image", gmix, "Base"); b.wire(grain, "Image", gmix, "Blend"); b.wire(gmix, "Image", soft); b.wire(soft, "Image", out)
        b.expose(sep, "intensity", "Sepia"); b.expose(lut, "amount", "Fade"); b.expose(vig, "intensity", "Vignette"); b.expose(dmix, "opacity", "Dust & Scratches")
        b.expose(lmix, "opacity", "Light Leak"); b.expose(gmix, "opacity", "Grain")
        b.frame("Overlays", around: [dust, dmix, leak, lmix, grain, gmix], color: RGBA(hex: "C27A3A")!)
    }

    static let woodPlanks = make("Wood Planks", "Procedural wood grain cut into planks and lit from its height.") { b in
        let tex = b.add("gen.wood", col: 0, ["scale": 260, "rings": 9])
        let planks = b.add("gen.bricks", col: 0, row: 1, ["scale": 90, "aspect": 5, "mortar": 0.04, "bevel": 0.1, "variation": 0.8, "rough": 0, "rotation": 90],
                           gradient: ("ramp", .twoColor(.black, .white, name: "Black, White")), title: "Plank Layout")
        let mul = b.add("imath.op", col: 1, ["op": 2], title: "Planks × Grain")
        let nrm = b.add("util.normal", col: 2, row: 1, ["strength": 7])
        let lit = b.add("util.light", col: 3, ["angle": 120, "elevation": 55, "specular": 0.25, "shininess": 25, "ambient": 0.45, "diffuse": 0.8])
        let out = b.add("out.output", col: 4)
        b.wire(tex, "Image", mul, "A"); b.wire(planks, "Image", mul, "B"); b.wire(mul, "Image", nrm, "Height")
        b.wire(nrm, "Normal", lit, "Normal"); b.wire(mul, "Image", lit, "Albedo"); b.wire(lit, "Image", out)
        b.expose(tex, "scale", "Grain Scale"); b.expose(planks, "scale", "Plank Width"); b.expose(tex, "ramp", "Wood Colors"); b.expose(nrm, "strength", "Relief"); b.expose(lit, "angle", "Light Angle")
    }
}
