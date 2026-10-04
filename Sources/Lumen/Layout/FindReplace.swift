import AppKit
import SwiftUI
import ImageCratCore

// MARK: - Model

struct TextQuery: Equatable {
    var find = ""
    var replace = ""
    var regex = false
    var caseSensitive = false
    var wholeWord = false
}

struct TextMatch: Identifiable, Equatable {
    var id: String { "\(layerID.uuidString)-\(range.location)-\(range.length)" }
    var layerID: UUID
    var layerName: String
    var range: NSRange
    /// Context around the match: (before, match, after).
    var before: String
    var match: String
    var after: String
}

struct ColorUse: Identifiable, Equatable {
    var id: String { hex }
    var color: RGBA
    var hex: String
    var count: Int
    var layers: [UUID]
    var kinds: [String]
}

struct FontUse: Identifiable, Equatable {
    var id: String { name }
    var name: String          // PostScript name stored in the type layer
    var display: String
    var count: Int
    var missing: Bool
    var layers: [UUID]
}

/// Edit ▸ Find and Replace in Document: text, colours and fonts across every layer.
enum DocReplace {
    // MARK: Text

    static func regex(_ q: TextQuery) -> NSRegularExpression? {
        guard !q.find.isEmpty else { return nil }
        var p = q.regex ? q.find : NSRegularExpression.escapedPattern(for: q.find)
        if q.wholeWord { p = "(?<![\\p{L}\\p{N}_])(?:" + p + ")(?![\\p{L}\\p{N}_])" }
        return try? NSRegularExpression(pattern: p, options: q.caseSensitive ? [] : [.caseInsensitive])
    }

    static func matches(_ q: TextQuery, in text: String) -> [NSTextCheckingResult] {
        guard let rx = regex(q) else { return [] }
        return rx.matches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length)).filter { $0.range.length > 0 }
    }

    /// All matches in all type layers, top layer first.
    static func textMatches(_ q: TextQuery, in st: DocumentState) -> [TextMatch] {
        var out: [TextMatch] = []
        for l in st.allLayers.reversed() {
            guard let t = l.text else { continue }
            let ns = t.text as NSString
            for m in matches(q, in: t.text) {
                let a = max(0, m.range.location - 18), b = min(ns.length, m.range.location + m.range.length + 18)
                func clean(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
                out.append(TextMatch(layerID: l.id, layerName: l.name, range: m.range,
                                     before: (a > 0 ? "…" : "") + clean(ns.substring(with: NSRange(location: a, length: m.range.location - a))),
                                     match: clean(ns.substring(with: m.range)),
                                     after: clean(ns.substring(with: NSRange(location: m.range.location + m.range.length, length: b - m.range.location - m.range.length))) + (b < ns.length ? "…" : "")))
            }
        }
        return out
    }

    /// Replaces a UTF-16 range, keeping the styled runs aligned (the new text takes the style at the start of the range).
    static func replace(in t: inout TextContent, range: NSRange, with new: String) {
        let ns = t.text as NSString
        guard range.location >= 0, range.location + range.length <= ns.length else { return }
        let newLen = (new as NSString).length
        let delta = newLen - range.length
        let lo = range.location, hi = range.location + range.length
        t.text = ns.replacingCharacters(in: range, with: new)
        t.runs = t.runs.compactMap { run in
            let a = run.location, b = run.end
            let na: Int = a <= lo ? a : (a >= hi ? a + delta : lo + newLen)
            let nb: Int = b <= lo ? b : (b >= hi ? b + delta : (a <= lo ? lo + newLen : lo + newLen))
            guard nb > na else { return nil }
            return TextStyleRun(location: na, length: nb - na, style: run.style)
        }
        t.normalizeRuns()
    }

    /// Replaces matches in the type layers. `only` limits it to specific matches (by id). Returns how many were replaced.
    @discardableResult
    static func replaceText(_ q: TextQuery, in st: inout DocumentState, only: Set<String>? = nil) -> Int {
        guard let rx = regex(q) else { return 0 }
        let template = q.regex ? q.replace : NSRegularExpression.escapedTemplate(for: q.replace)
        var n = 0
        for l in st.allLayers {
            guard var t = l.text else { continue }
            let found = matches(q, in: t.text)
            guard !found.isEmpty else { continue }
            let original = t.text
            var changed = false
            for m in found.reversed() {
                if let only, !only.contains("\(l.id.uuidString)-\(m.range.location)-\(m.range.length)") { continue }
                let new = rx.replacementString(for: m, in: original, offset: 0, template: template)
                replace(in: &t, range: m.range, with: new)
                n += 1
                changed = true
            }
            if changed { st.updateLayer(l.id) { $0.text = t } }
        }
        return n
    }

    // MARK: Colours

    private static func map(_ p: inout PaintStyle, _ kind: String, _ f: (RGBA, String) -> RGBA) {
        switch p {
        case .color(let c): p = .color(f(c, kind))
        case .gradient(var g):
            for i in g.gradient.stops.indices { g.gradient.stops[i].color = f(g.gradient.stops[i].color, "Gradient") }
            p = .gradient(g)
        default: break
        }
    }

    private static func map(_ g: inout ColorGradient, _ f: (RGBA, String) -> RGBA) {
        for i in g.stops.indices { g.stops[i].color = f(g.stops[i].color, "Gradient") }
    }

    /// Visits every editable colour of a layer (and its children): shape fill / stroke, type, fill layers, enabled effects,
    /// gradient stops and artboard backgrounds. `f` returns the colour to store.
    static func mapColors(_ l: inout Layer, _ f: (RGBA, String) -> RGBA) {
        switch l.content {
        case .shape(var s):
            map(&s.fill, "Fill", f)
            map(&s.stroke.paint, "Stroke", f)
            l.content = .shape(s)
        case .text(var t):
            t.color = f(t.color, "Type")
            for i in t.runs.indices { if let c = t.runs[i].style.color { t.runs[i].style.color = f(c, "Type") } }
            l.content = .text(t)
        case .fill(var fc):
            map(&fc.paint, "Fill layer", f)
            l.content = .fill(fc)
        case .group(var g):
            if let bg = g.artboard?.background { g.artboard?.background = f(bg, "Artboard") }
            for i in g.children.indices { mapColors(&g.children[i], f) }
            l.content = .group(g)
        default: break
        }
        guard l.effects.enabled, l.effects.hasAny else { return }
        var fx = l.effects
        func shadow(_ s: inout ShadowEffect) { if s.enabled { s.color = f(s.color, "Effect") } }
        func glow(_ g: inout GlowEffect) {
            guard g.enabled else { return }
            if g.useGradient { map(&g.gradient, f) } else { g.color = f(g.color, "Effect") }
        }
        func overlay(_ o: inout ColorOverlayEffect) { if o.enabled { o.color = f(o.color, "Effect") } }
        func gradient(_ o: inout GradientOverlayEffect) { if o.enabled { map(&o.fill.gradient, f) } }
        func stroke(_ s: inout StrokeEffect) { if s.enabled { map(&s.paint, "Effect", f) } }
        shadow(&fx.dropShadow); shadow(&fx.innerShadow)
        for i in fx.extraDropShadows.indices { shadow(&fx.extraDropShadows[i]) }
        for i in fx.extraInnerShadows.indices { shadow(&fx.extraInnerShadows[i]) }
        glow(&fx.outerGlow); glow(&fx.innerGlow)
        if fx.satin.enabled { fx.satin.color = f(fx.satin.color, "Effect") }
        overlay(&fx.colorOverlay)
        for i in fx.extraColorOverlays.indices { overlay(&fx.extraColorOverlays[i]) }
        gradient(&fx.gradientOverlay)
        for i in fx.extraGradientOverlays.indices { gradient(&fx.extraGradientOverlays[i]) }
        stroke(&fx.stroke)
        for i in fx.extraStrokes.indices { stroke(&fx.extraStrokes[i]) }
        if fx != l.effects { l.effects = fx }
    }

    /// Every colour used in the document with how often and where, most used first.
    static func colors(in st: DocumentState) -> [ColorUse] {
        var uses: [String: ColorUse] = [:]
        var order: [String] = []
        for top in st.layers {
            // visit leaf by leaf so usages are attributed to the right layer
            for leaf in [top] + top.children.allLayers {
                var shallow = leaf
                if case .group(var g) = shallow.content { g.children = []; shallow.content = .group(g) }
                mapColors(&shallow) { c, kind in
                    guard c.a > 0.001 else { return c }
                    let hex = c.hex
                    if uses[hex] == nil { uses[hex] = ColorUse(color: RGBA(r: c.r, g: c.g, b: c.b), hex: hex, count: 0, layers: [], kinds: []); order.append(hex) }
                    uses[hex]!.count += 1
                    if !uses[hex]!.layers.contains(leaf.id) { uses[hex]!.layers.append(leaf.id) }
                    if !uses[hex]!.kinds.contains(kind) { uses[hex]!.kinds.append(kind) }
                    return c
                }
            }
        }
        return order.compactMap { uses[$0] }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.hex < $1.hex }
    }

    /// Distance between two colours in 8-bit RGB units (0…441).
    static func distance(_ a: RGBA, _ b: RGBA) -> Double {
        let dr = (a.r - b.r) * 255, dg = (a.g - b.g) * 255, db = (a.b - b.b) * 255
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    /// Replaces a colour everywhere (within `tolerance`), keeping each usage's own opacity. Returns the number of replacements.
    @discardableResult
    static func replaceColor(_ from: RGBA, with to: RGBA, tolerance: Double, in st: inout DocumentState) -> Int {
        var n = 0
        for i in st.layers.indices {
            mapColors(&st.layers[i]) { c, _ in
                guard c.a > 0.001, distance(c, from) <= max(0.75, tolerance) else { return c }
                n += 1
                return RGBA(r: to.r, g: to.g, b: to.b, a: c.a * to.a)
            }
        }
        return n
    }

    // MARK: Fonts

    static func displayName(_ postScript: String) -> String {
        NSFont(name: postScript, size: 12)?.displayName ?? postScript
    }

    static func isMissing(_ postScript: String) -> Bool { NSFont(name: postScript, size: 12) == nil }

    static func fonts(in st: DocumentState) -> [FontUse] {
        var uses: [String: FontUse] = [:]
        for l in st.allLayers {
            guard let t = l.text else { continue }
            for name in SelectSimilar.fonts(t) {
                if uses[name] == nil { uses[name] = FontUse(name: name, display: displayName(name), count: 0, missing: isMissing(name), layers: []) }
                uses[name]!.count += 1
                uses[name]!.layers.append(l.id)
            }
        }
        return uses.values.sorted { $0.missing != $1.missing ? $0.missing : ($0.count != $1.count ? $0.count > $1.count : $0.name < $1.name) }
    }

    /// Replaces a font (layer defaults and styled ranges). Returns the number of layers changed.
    @discardableResult
    static func replaceFont(_ from: String, with to: String, in st: inout DocumentState) -> Int {
        guard from != to, !to.isEmpty else { return 0 }
        var n = 0
        for l in st.allLayers {
            guard var t = l.text, SelectSimilar.fonts(t).contains(from) || t.fontName == from else { continue }
            if t.fontName == from { t.fontName = to }
            for i in t.runs.indices where t.runs[i].style.fontName == from { t.runs[i].style.fontName = to }
            t.normalizeRuns()
            st.updateLayer(l.id) { $0.text = t }
            n += 1
        }
        return n
    }

    // MARK: Navigation

    /// Selects a layer, opens the groups around it and scrolls the canvas so it is visible.
    static func reveal(_ id: UUID, in d: Document) {
        var st = d.state
        var opened = false
        var p = st.parentID(of: id)
        while let pid = p {
            if st.layer(pid)?.isExpanded == false { st.updateLayer(pid) { $0.isExpanded = true }; opened = true }
            p = st.parentID(of: pid)
        }
        if opened { d.state = st }
        d.selectLayer(id)
        guard let c = AppActions.canvas, c.document === d, let b = LayoutGeom.bounds(id, d.state) else { return }
        let v = c.docToView(CGPoint(x: b.midX, y: b.midY))
        let visible = c.bounds.insetBy(dx: 60, dy: 60)
        if !visible.contains(v) { c.pan(by: CGPoint(x: c.bounds.midX - v.x, y: c.bounds.midY - v.y)) }
    }
}

// MARK: - Dialog

struct FindReplaceDialog: View {
    enum Tab: String, CaseIterable, Identifiable { case text = "Text", colors = "Colours", fonts = "Fonts"; var id: String { rawValue } }
    @State private var tab: Tab = .text
    @State private var q = TextQuery()
    @State private var matches: [TextMatch] = []
    @State private var colors: [ColorUse] = []
    @State private var fonts: [FontUse] = []
    @State private var fromColor: String?
    @State private var toColor = RGBA(hex: "E94F37")!
    @State private var tolerance: Double = 0
    @State private var fromFont: String?
    @State private var toFamily = "Helvetica Neue"
    @State private var toFont = "HelveticaNeue"
    @State private var message = ""
    @Bindable var app = AppModel.shared

    var body: some View {
        DialogFrame(title: "Find and Replace in Document", width: 430, okTitle: "Done", onOK: {}) {
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            switch tab {
            case .text: textTab
            case .colors: colorTab
            case .fonts: fontTab
            }
            if !message.isEmpty { Text(message).font(Theme.fontSmall).foregroundStyle(Theme.textDim) }
        }
        .onAppear { refresh() }
        .onChange(of: tab) { _, _ in message = ""; refresh() }
        .onChange(of: q) { _, _ in refresh() }
        .onChange(of: app.activeDocument?.revision) { _, _ in refresh() }
    }

    private var doc: Document? { app.activeDocument }

    private func refresh() {
        guard let d = doc else { matches = []; colors = []; fonts = []; return }
        switch tab {
        case .text: matches = DocReplace.textMatches(q, in: d.state)
        case .colors:
            colors = DocReplace.colors(in: d.state)
            if fromColor == nil || !colors.contains(where: { $0.hex == fromColor }) { fromColor = colors.first?.hex }
        case .fonts:
            fonts = DocReplace.fonts(in: d.state)
            if fromFont == nil || !fonts.contains(where: { $0.name == fromFont }) { fromFont = fonts.first?.name }
        }
    }

    // MARK: Text

    @ViewBuilder private var textTab: some View {
        HStack { Text("Find").foregroundStyle(Theme.textDim).frame(width: 56, alignment: .leading); TextField("", text: $q.find).textFieldStyle(.roundedBorder) }
        HStack { Text("Replace").foregroundStyle(Theme.textDim).frame(width: 56, alignment: .leading); TextField("", text: $q.replace).textFieldStyle(.roundedBorder) }
        HStack {
            Toggle2(label: "Match case", on: $q.caseSensitive)
            Toggle2(label: "Whole word", on: $q.wholeWord)
            Toggle2(label: "Regular expression", on: $q.regex)
        }
        if q.regex && !q.find.isEmpty && DocReplace.regex(q) == nil {
            Text("This is not a valid regular expression.").font(Theme.fontSmall).foregroundStyle(.orange)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(matches.prefix(300)) { m in
                    HStack(spacing: 6) {
                        Text(m.layerName).foregroundStyle(Theme.textDim).lineLimit(1).frame(width: 110, alignment: .leading)
                        (Text(m.before).foregroundStyle(Theme.textDim) + Text(m.match).bold().foregroundStyle(Theme.accent) + Text(m.after).foregroundStyle(Theme.textDim))
                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Replace") { replace(only: [m.id]) }.buttonStyle(.plain).foregroundStyle(Theme.accent).font(Theme.fontSmall)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { if let d = doc { DocReplace.reveal(m.layerID, in: d) } }
                }
            }
        }
        .frame(height: 170)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
        HStack {
            let layers = Set(matches.map(\.layerID)).count
            Text(q.find.isEmpty ? "Type what to look for. Click a result to jump to its layer."
                 : "\(matches.count) match\(matches.count == 1 ? "" : "es") in \(layers) layer\(layers == 1 ? "" : "s")")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            Spacer()
            Button("Replace All") { replace(only: nil) }.buttonStyle(PanelButtonStyle()).disabled(matches.isEmpty)
        }
    }

    private func replace(only: Set<String>?) {
        guard let d = doc else { return }
        var st = d.state
        let n = DocReplace.replaceText(q, in: &st, only: only)
        guard n > 0 else { return }
        d.state = st
        d.commit(n == 1 ? "Replace Text" : "Replace Text (\(n))")
        message = "Replaced \(n) occurrence\(n == 1 ? "" : "s")."
        refresh()
    }

    // MARK: Colours

    @ViewBuilder private var colorTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(colors) { c in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: c.color.nsColor)).frame(width: 26, height: 16)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.45), lineWidth: 0.5))
                        Text("#" + c.hex).font(Theme.mono)
                        Text(c.kinds.joined(separator: ", ")).foregroundStyle(Theme.textDim).lineLimit(1)
                        Spacer()
                        Text("\(c.count)×").foregroundStyle(Theme.textDim)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(fromColor == c.hex ? Theme.accent.opacity(0.35) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { fromColor = c.hex }
                }
                if colors.isEmpty { Text("No editable colours (shapes, type, fill layers, effects) in this document.").foregroundStyle(Theme.textFaint).padding(8) }
            }
        }
        .frame(height: 190)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
        HStack {
            Text("Replace with").foregroundStyle(Theme.textDim)
            ColorWell(color: $toColor)
            Text("#" + toColor.hex).font(Theme.mono).foregroundStyle(Theme.textDim)
            Spacer()
            Button("Select Layers") {
                if let d = doc, let use = colors.first(where: { $0.hex == fromColor }), let first = use.layers.last {
                    DocReplace.reveal(first, in: d)
                    d.selectedLayerIDs = Set(use.layers)
                }
            }.buttonStyle(PanelButtonStyle()).disabled(fromColor == nil)
        }
        ValueSlider(label: "Tolerance", value: $tolerance, range: 0...120, labelWidth: 70)
        HStack {
            Text("Tolerance also catches near-identical shades. Opacity of each use is kept.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            Spacer()
            Button("Replace Colour") { replaceColor() }.buttonStyle(PanelButtonStyle()).disabled(fromColor == nil)
        }
    }

    private func replaceColor() {
        guard let d = doc, let use = colors.first(where: { $0.hex == fromColor }) else { return }
        var st = d.state
        let n = DocReplace.replaceColor(use.color, with: toColor, tolerance: tolerance, in: &st)
        guard n > 0 else { return }
        d.state = st
        d.commit("Replace Colour")
        message = "Replaced #\(use.hex) in \(n) place\(n == 1 ? "" : "s")."
        fromColor = toColor.hex
        refresh()
    }

    // MARK: Fonts

    @ViewBuilder private var fontTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(fonts) { f in
                    HStack(spacing: 8) {
                        Text(f.display).lineLimit(1)
                        if f.missing { Text("Missing").font(Theme.fontSmall).padding(.horizontal, 5).background(Capsule().fill(Color.orange.opacity(0.8))) }
                        Spacer()
                        Text("\(f.count) layer\(f.count == 1 ? "" : "s")").foregroundStyle(Theme.textDim)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 3).fill(fromFont == f.name ? Theme.accent.opacity(0.35) : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { fromFont = f.name }
                }
                if fonts.isEmpty { Text("This document has no type layers.").foregroundStyle(Theme.textFaint).padding(8) }
            }
        }
        .frame(height: 170)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
        let missing = fonts.filter(\.missing).count
        if missing > 0 {
            Text("\(missing) font\(missing == 1 ? " is" : "s are") not installed on this Mac and \(missing == 1 ? "is" : "are") shown with a fallback.")
                .font(Theme.fontSmall).foregroundStyle(.orange)
        }
        HStack {
            Picker("Replace with", selection: $toFamily) {
                ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
            }.frame(width: 250)
            Picker("", selection: $toFont) {
                ForEach(members(toFamily), id: \.0) { m in Text(m.1).tag(m.0) }
            }.labelsHidden().frame(width: 120)
        }
        .onChange(of: toFamily) { _, fam in
            let m = members(fam)
            toFont = (m.first { $0.1 == "Regular" } ?? m.first)?.0 ?? toFont
        }
        HStack {
            Button("Select Layers") {
                if let d = doc, let use = fonts.first(where: { $0.name == fromFont }), let first = use.layers.last {
                    DocReplace.reveal(first, in: d)
                    d.selectedLayerIDs = Set(use.layers)
                }
            }.buttonStyle(PanelButtonStyle()).disabled(fromFont == nil)
            Spacer()
            Button("Replace Font") { replaceFont() }.buttonStyle(PanelButtonStyle()).disabled(fromFont == nil)
        }
    }

    /// (PostScript name, style name) of a family's members.
    private func members(_ family: String) -> [(String, String)] {
        (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap { m in
            guard m.count >= 2, let ps = m[0] as? String, let style = m[1] as? String else { return nil }
            return (ps, style)
        }
    }

    private func replaceFont() {
        guard let d = doc, let from = fromFont else { return }
        var st = d.state
        let n = DocReplace.replaceFont(from, with: toFont, in: &st)
        guard n > 0 else { return }
        d.state = st
        d.commit("Replace Font")
        Compositor.shared.clearCaches()
        message = "Replaced \(DocReplace.displayName(from)) in \(n) layer\(n == 1 ? "" : "s")."
        fromFont = toFont
        refresh()
    }
}
