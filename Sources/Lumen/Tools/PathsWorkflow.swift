import AppKit
import SwiftUI
import ImageCratCore

// Paths as Photoshop handles them: non-printing outlines kept in the Paths panel.
// - Path mode (Pen, Freeform Pen, Curvature Pen, every shape tool) adds only an outline: no layer, no fill, no stroke,
//   no pixels. Each tool remembers its Shape / Path / Pixels mode (Pens: Shape / Path; they start in Path mode).
// - The active path shows as a thin outline whatever the tool, until Esc / Return (path tools) or a click on empty
//   space in the Paths panel deselects it. It never renders into the image or an export.
// - "Work Path" is temporary: a new path drawn while no path is active replaces it, unless it was saved (double-click
//   it in the Paths panel → "Path 1", …).
// - Paths turn into other things only by explicit, undoable commands: Make Selection, Fill Path, Stroke Path, vector
//   mask, shape layer (options bar "Make:" buttons, Paths panel buttons and menu).

enum PathsModule {
    static func register() {
        MenuRegistry.add("Type", "Type on Path", dividerBefore: true, enabled: { AppActions.doc != nil }) { TypeOnPath.startFromMenu() }
        MenuRegistry.add("View", "Show Target Path", enabled: { AppActions.doc != nil }, checked: { PathOverlay.showTargetPath }) {
            PathOverlay.showTargetPath.toggle()
            AppActions.canvas?.overlay.needsDisplay = true
        }
        DialogRegistry.register(FillPathDialog.id) { AnyView(FillPathDialog()) }
        DialogRegistry.register(StrokePathDialog.id) { AnyView(StrokePathDialog()) }
        DialogRegistry.register(MakeSelectionDialog.id) { AnyView(MakeSelectionDialog()) }
        DialogRegistry.register(MakeWorkPathDialog.id) { AnyView(MakeWorkPathDialog()) }
        FeatureModules.selfTests.append(("typepath", { TypePathSelfTest.run($0) }))
        FeatureModules.selfTests.append(("paths2", { Paths2SelfTest.run($0) }))
        FeatureModules.selfTests.append(("typelink", { TypePathLinkSelfTest.run($0) }))
        TypePathLink.install()
    }
}

// MARK: - Shape / Path / Pixels mode, remembered per tool

enum ToolModes {
    static let key = "Lumen.Tools.ShapeModes"
    /// Automated runs (self tests, fuzzing) neither read nor write the user's remembered modes.
    static var automated: Bool { GenAIKeyOverrides.realKeysBlocked }
    nonisolated(unsafe) static var memory: [String: String] = automated ? [:] : (UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:])

    static func isPen(_ k: ToolKind) -> Bool { [.pen, .freeformPen, .curvaturePen].contains(k) }
    static func usesModes(_ k: ToolKind) -> Bool { isPen(k) || k.isShape }
    /// Pens draw shapes or paths (Photoshop has no Pixels mode for them).
    static func modes(for k: ToolKind) -> [ShapeMode] { isPen(k) ? [.shape, .path] : ShapeMode.allCases }

    static func current(_ k: ToolKind) -> ShapeMode {
        let app = AppModel.shared
        if isPen(k) { return app.penMode == .pixels ? .path : app.penMode }
        return app.shapeTool.mode
    }

    /// Mode picked in the options bar: applied and remembered for this tool.
    static func set(_ m: ShapeMode, for k: ToolKind) {
        apply(m, k)
        memory[k.rawValue] = m.rawValue
        if !automated { UserDefaults.standard.set(memory, forKey: key) }
    }

    /// Tool activated: its remembered mode comes back (other tools of the group keep theirs).
    static func restore(_ k: ToolKind) {
        if let raw = memory[k.rawValue], let m = ShapeMode(rawValue: raw), modes(for: k).contains(m) { apply(m, k) }
        else if isPen(k), AppModel.shared.penMode == .pixels { AppModel.shared.penMode = .path }
    }

    private static func apply(_ m: ShapeMode, _ k: ToolKind) {
        let app = AppModel.shared
        if isPen(k) { if app.penMode != m { app.penMode = m } } else if app.shapeTool.mode != m { app.shapeTool.mode = m }
    }

    static func symbol(_ m: ShapeMode) -> String {
        switch m {
        case .shape: return "square.on.circle"
        case .path: return "point.topleft.down.to.point.bottomright.curvepath"
        case .pixels: return "square.grid.3x3.fill"
        }
    }

    static func help(_ m: ShapeMode) -> String {
        switch m {
        case .shape: return "Shape: draws a new shape layer (fill and stroke, editable)"
        case .path: return "Path: draws only an outline in the Paths panel; nothing is painted (Make: Selection, Mask or Shape turns it into one)"
        case .pixels: return "Pixels: paints the shape with the foreground color (options-bar Mode and Opacity) on the selected pixel layer"
        }
    }
}

/// Shape / Path / Pixels selector for the pen and shape tools (the mode is remembered per tool).
struct ToolModePicker: View {
    @Bindable var app = AppModel.shared
    let tool: ToolKind
    var body: some View {
        let modes = ToolModes.modes(for: tool)
        let cur = ToolModes.current(tool)
        // a pop-up naming the mode (Photoshop's "Shape ▾"): the options to its right change with it
        Picker("", selection: Binding(get: { ToolModes.current(tool) }, set: { ToolModes.set($0, for: tool) })) {
            ForEach(modes, id: \.self) { m in Label(m.rawValue, systemImage: ToolModes.symbol(m)).tag(m).help(ToolModes.help(m)) }
        }
        .pickerStyle(.menu)
        .frame(width: 92)
        .labelsHidden()
        .help("Tool mode: \(cur.rawValue)\n" + modes.map(ToolModes.help).joined(separator: "\n"))
        if ToolModes.current(tool) == .path { PathMakeButtons() }
    }
}

/// Options bar in Path mode: Make Selection… / Mask / Shape from the active path (Photoshop's "Make:" buttons).
struct PathMakeButtons: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        let has = app.activeDocument.map { PathOps.actionPath($0, includeShape: false) != nil } ?? false
        Text("Make:").foregroundStyle(Theme.textDim)
        Button("Selection…") { DialogRegistry.show(MakeSelectionDialog.id) }.buttonStyle(PanelButtonStyle()).disabled(!has)
            .help("Load the active path as a selection (feather, anti-alias, combine)")
        Button("Mask") { if let d = AppActions.doc { PathOps.addVectorMask(d) } }.buttonStyle(PanelButtonStyle()).disabled(!has)
            .help("Add the active path to the active layer as a vector mask")
        Button("Shape") { if let d = AppActions.doc { PathOps.makeShape(d) } }.buttonStyle(PanelButtonStyle()).disabled(!has)
            .help("Make a shape layer (foreground fill) from the active path")
    }
}

// MARK: - Active path outline (non-printing)

enum PathOverlay {
    /// View ▸ Show Target Path.
    nonisolated(unsafe) static var showTargetPath = true

    static func draw(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        guard showTargetPath else { return }
        if let pid = doc.activePathID, let np = doc.state.paths.first(where: { $0.id == pid }), !np.path.isEmpty {
            VectorEditing.drawPath(ctx, np.path, canvas: canvas, anchors: false)
        } else if let (_, vp) = typePath(doc), !(TextTool.editing?.isEditing(doc.activeLayerID) ?? false) {
            VectorEditing.drawPath(ctx, vp, canvas: canvas, anchors: false)   // the selected type layer's own path
        }
    }

    /// The active type-on-a-path layer and its path (doc coordinates): "<layer> Type Path".
    static func typePath(_ d: Document) -> (Layer, VectorPath)? {
        guard let l = d.activeLayer, let t = l.text, let p = t.pathText, !p.path.isEmpty else { return nil }
        return (l, t.transform.isIdentity ? p.path : p.path.applying(t.transform))
    }
}

extension VectorEditing {
    /// The active work path picked on the canvas by a path tool while a shape layer is active: it stays the tools'
    /// target until another layer is selected or the path is deselected.
    nonisolated(unsafe) static var picked: (path: UUID, layer: UUID?)?

    static func pickedWorkPath(_ d: Document) -> UUID? {
        guard let p = picked else { return nil }
        // another layer was selected (or the path deselected / deleted) since: the pick is over
        guard p.path == d.activePathID, p.layer == d.activeLayerID, d.state.paths.contains(where: { $0.id == p.path }) else { picked = nil; return nil }
        return p.path
    }

    static func pickWorkPath(_ d: Document, _ pid: UUID?) {
        guard let pid else { picked = nil; return }
        d.activePathID = pid
        picked = (pid, d.activeLayerID)
    }

    /// The active path (shown on the canvas) when `p` lies on its outline (or inside a closed component, `interior`).
    static func workPathHit(_ d: Document, _ p: CGPoint, tolerance: CGFloat, interior: Bool = false) -> UUID? {
        guard PathOverlay.showTargetPath, let pid = d.activePathID, let np = d.state.paths.first(where: { $0.id == pid }) else { return nil }
        for sp in np.path.subpaths where sp.points.count >= 2 {
            if PathSampler(VectorPath(subpaths: [sp])).nearest(p).distance <= tolerance { return pid }
            if interior, sp.closed, sp.cgPath.contains(p) { return pid }
        }
        return nil
    }
}

// MARK: - Path commands

enum PathOps {
    static let workPathName = "Work Path"

    /// Esc / Return with a path tool, or a click on empty space in the Paths panel: no path is active (none shown).
    static func deselectPath(_ d: Document) {
        VectorEditing.picked = nil
        guard d.activePathID != nil else { return }
        d.activePathID = nil
        AppActions.canvas?.overlay.needsDisplay = true
        AppModel.shared.sessionTick += 1
    }

    static func selectPath(_ d: Document, _ id: UUID) {
        d.activePathID = id
        AppActions.canvas?.overlay.needsDisplay = true
        AppModel.shared.sessionTick += 1
    }

    /// The path a command acts on: the active path, else (`includeShape`) the active shape layer's outline.
    static func actionPath(_ d: Document, includeShape: Bool = true) -> (path: VectorPath, id: UUID?, name: String)? {
        if let pid = d.activePathID, let np = d.state.paths.first(where: { $0.id == pid }), !np.path.isEmpty { return (np.path, pid, np.name) }
        if includeShape, let l = d.activeLayer, let s = l.shape { return (s.path, nil, "\(l.name) Shape Path") }
        if includeShape, let (l, p) = PathOverlay.typePath(d) { return (p, nil, "\(l.name) Type Path") }
        return nil
    }

    static func path(_ d: Document, _ id: UUID?) -> VectorPath? {
        if let id { return d.state.paths.first { $0.id == id }?.path }
        return actionPath(d)?.path
    }

    static func nextPathName(_ d: Document) -> String {
        var n = 1
        while d.state.paths.contains(where: { $0.name == "Path \(n)" }) { n += 1 }
        return "Path \(n)"
    }

    /// Double-click on the Work Path (or Save Path): it becomes a saved path that new paths no longer replace.
    @discardableResult
    static func saveWorkPath(_ d: Document, name: String? = nil) -> UUID? {
        guard let i = d.state.paths.firstIndex(where: { $0.name == workPathName }) else { return nil }
        d.state.paths[i].name = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? nextPathName(d)
        d.activePathID = d.state.paths[i].id
        d.commit("Save Path")
        return d.state.paths[i].id
    }

    static func rename(_ d: Document, _ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = d.state.paths.firstIndex(where: { $0.id == id }), d.state.paths[i].name != n else { return }
        d.state.paths[i].name = n
        d.commit("Rename Path")
    }

    @discardableResult
    static func newPath(_ d: Document) -> UUID {
        let np = NamedPath(name: nextPathName(d), path: VectorPath())
        d.state.paths.append(np)
        d.activePathID = np.id
        d.commit("New Path")
        return np.id
    }

    /// Duplicate Path: a saved copy of a path, or of the active shape layer's outline (`id` nil).
    @discardableResult
    static func duplicate(_ d: Document, _ id: UUID?) -> UUID? {
        let src: (VectorPath, String)?
        if let id, let np = d.state.paths.first(where: { $0.id == id }) { src = (np.path, np.name == workPathName ? nextPathName(d) : np.name + " copy") }
        else if id == nil, let l = d.activeLayer, let s = l.shape { src = (s.path, "\(l.name) Shape Path copy") }
        else if id == nil, let (l, p) = PathOverlay.typePath(d) { src = (p, "\(l.name) Type Path copy") }
        else { src = nil }
        guard let (p, name) = src, !p.isEmpty else { Beep.play(); return nil }
        let np = NamedPath(name: name, path: p)
        d.state.paths.append(np)
        d.activePathID = np.id
        d.commit("Duplicate Path")
        return np.id
    }

    static func delete(_ d: Document, _ id: UUID) {
        guard d.state.paths.contains(where: { $0.id == id }) else { return }
        AppActions.deletePath(id)
    }

    // MARK: Fill / stroke / selection

    enum FillContents: String, CaseIterable { case foreground = "Foreground Color", background = "Background Color", black = "Black", white = "White", gray = "50% Gray" }
    struct FillOptions: Equatable {
        var contents: FillContents = .foreground
        var opacity: Double = 100       // %
        var feather: Double = 0         // px
        var antialias = true
    }

    /// The pixels Fill / Stroke Path paint: the Quick Mask, the active layer's mask (when it is the target) or the active
    /// pixel layer. nil (with a status message) for anything else.
    static func paintTarget(_ d: Document) -> (UUID, EditTarget)? {
        if d.quickMask { return (d.activeLayerID ?? d.state.layers.last?.id ?? UUID(), .quickMask) }
        guard let lid = d.activeLayerID, let l = d.state.layer(lid) else { AppModel.shared.setStatus("Select a pixel layer to fill or stroke the path."); return nil }
        if l.locks.all || !l.isVisible { AppModel.shared.setStatus(l.isVisible ? "The layer is locked." : "The layer is hidden."); return nil }
        if d.editTarget == .mask, l.mask != nil { return (lid, .mask) }
        guard l.isRaster, !l.locks.pixelsLocked else {
            AppModel.shared.setStatus(l.isRaster ? "The layer is locked." : "Fill Path and Stroke Path paint pixels: select a pixel layer (or rasterize this one).")
            return nil
        }
        return (lid, .content)
    }

    static func color(_ c: FillContents) -> RGBA {
        let app = AppModel.shared
        switch c {
        case .foreground: return app.foreground
        case .background: return app.background
        case .black: return RGBA(gray: 0)
        case .white: return RGBA(gray: 1)
        case .gray: return RGBA(gray: 0.5)
        }
    }

    /// Fill Path: the path's area (anti-aliased, feathered) in a color at an opacity, one history step.
    @discardableResult
    static func fill(_ d: Document, _ id: UUID? = nil, _ o: FillOptions = FillOptions()) -> Bool {
        guard let p = path(d, id), !p.isEmpty else { Beep.play(); return false }
        guard let (lid, tgt) = paintTarget(d), let (w, origin) = d.beginPixelEdit(layerID: lid, target: tgt) else { Beep.play(); return false }
        let rp = p.resolved
        var m = SelectionOps.mask(fromPath: rp.path, width: d.state.width, height: d.state.height, antialias: o.antialias, evenOdd: rp.evenOdd)
        if o.feather > 0 { m = SelectionOps.feather(m, radius: o.feather) }
        let mask = m.makeCGImage()
        let c = color(o.contents)
        let ctx = w.context
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(-origin.x), y: CGFloat(-origin.y))
        w.clip(toMask: mask, in: d.state.canvasCGRect)
        var paint = tgt.isMask ? RGBA(gray: c.luminance) : c
        paint.a *= max(0, min(1, o.opacity / 100))
        ctx.setFillColor(paint.cgColor)
        ctx.fill(d.state.canvasCGRect)
        ctx.restoreGState()
        w.markDirty()
        d.commit("Fill Path")
        return true
    }

    struct StrokeOptions: Equatable {
        var tool: ToolKind = .brush
        var simulatePressure = false
    }
    static let strokeTools: [ToolKind] = [.brush, .pencil, .eraser, .historyBrush, .blur, .sharpen, .smudge, .dodge, .burn, .sponge]

    /// Stroke Path: drives the chosen painting tool (with its current settings) along every subpath, like Photoshop.
    /// Simulate Pressure tapers each stroke (pen pressure 0 → 1 → 0). One history step.
    @discardableResult
    static func stroke(_ d: Document, _ id: UUID? = nil, _ o: StrokeOptions = StrokeOptions()) -> Bool {
        guard let p = path(d, id), !p.isEmpty else { Beep.play(); return false }
        guard paintTarget(d) != nil else { Beep.play(); return false }
        guard let canvas = AppActions.canvas, canvas.document === d, strokeTools.contains(o.tool) else { return strokeCG(d, p) }
        let tool = Tool.make(o.tool, canvas: canvas)
        let h0 = d.historyIndex
        let step = max(0.5, min(2, 1 / max(0.05, canvas.zoom)))
        for sp in p.subpaths where sp.points.count >= 2 {
            let sampler = PathSampler(VectorPath(subpaths: [sp]))
            let total = sampler.total
            guard total > 0 else { continue }
            let n = max(2, Int(ceil(total / step)))
            func event(_ i: Int) -> ToolEvent {
                let u = CGFloat(i) / CGFloat(n)
                let pt = sampler.sample(u * total)?.0 ?? sp.points[0].anchor
                let pressure = o.simulatePressure ? max(0.02, Double(sin(.pi * u))) : 1
                return ToolEvent(doc: pt, view: canvas.docToView(pt), pressure: pressure, modifiers: [], clickCount: 1, isTablet: o.simulatePressure)
            }
            tool.mouseDown(event(0))
            for i in 1..<n { tool.mouseDragged(event(i)) }
            tool.mouseUp(event(n))
        }
        tool.deactivate()
        let added = d.historyIndex - h0
        if added > 1 { d.coalesceLastSteps(added, name: "Stroke Path") }
        else if added == 1 { d.commitReplacingLast("Stroke Path") }
        else { d.revertUncommitted(); return false }
        d.setNeedsRender()
        return true
    }

    /// Stroke Path without a canvas (scripts): a round stroke of the brush size in the foreground color.
    private static func strokeCG(_ d: Document, _ p: VectorPath) -> Bool {
        guard let (lid, tgt) = paintTarget(d), let (w, o) = d.beginPixelEdit(layerID: lid, target: tgt) else { return false }
        let app = AppModel.shared
        let ctx = w.context
        ctx.saveGState()
        ctx.translateBy(x: CGFloat(-o.x), y: CGFloat(-o.y))
        ctx.addPath(p.cgPath)
        ctx.setStrokeColor((tgt.isMask ? RGBA(gray: app.foreground.luminance) : app.foreground).cgColor)
        ctx.setLineWidth(CGFloat(max(1, app.brush.size)))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()
        w.markDirty()
        d.commit("Stroke Path")
        return true
    }

    struct SelectionOptions: Equatable {
        var feather: Double = 0
        var antialias = true
        var mode: SelectionCombine = .new
    }

    /// Make Selection: the path's area as a selection (feathered, anti-aliased, combined with the current one).
    @discardableResult
    static func makeSelection(_ d: Document, _ id: UUID? = nil, _ o: SelectionOptions = SelectionOptions()) -> Bool {
        guard let p = path(d, id), !p.isEmpty else { Beep.play(); return false }
        let rp = p.resolved
        var m = SelectionOps.mask(fromPath: rp.path, width: d.state.width, height: d.state.height, antialias: o.antialias, evenOdd: rp.evenOdd)
        if o.feather > 0 { m = SelectionOps.feather(m, radius: o.feather, direction: AppModel.shared.featherDirection) }
        let result = o.mode == .new ? m : SelectionOps.combine(d.state.selection, m, mode: o.mode)
        d.setSelection(result, commitName: "Make Selection")
        return true
    }

    /// Make Work Path from the selection; `tolerance` (px) simplifies the traced outline. Replaces the Work Path.
    @discardableResult
    static func makeWorkPath(_ d: Document, tolerance: Double = 2) -> Bool {
        guard d.state.selection != nil else { AppModel.shared.setStatus("Make a selection first."); Beep.play(); return false }
        AppActions.workPathFromSelection(tolerance: tolerance)
        return true
    }

    /// Mask: the path becomes the active layer's vector mask.
    @discardableResult
    static func addVectorMask(_ d: Document, _ id: UUID? = nil) -> Bool {
        guard let lid = d.activeLayerID, let l = d.state.layer(lid), let p = path(d, id), !p.isEmpty else { Beep.play(); return false }
        if l.locks.all { AppModel.shared.setStatus("The layer is locked."); Beep.play(); return false }
        d.updateLayer(lid) { $0.vectorMask = p; $0.vectorMaskEnabled = true }
        d.commit("Add Vector Mask")
        return true
    }

    /// Shape: a new shape layer (foreground fill, the shape tool's stroke) from the path; the path is kept.
    @discardableResult
    static func makeShape(_ d: Document, _ id: UUID? = nil) -> Bool {
        guard let p = id.flatMap({ i in d.state.paths.first { $0.id == i }?.path }) ?? actionPath(d, includeShape: false)?.path, !p.isEmpty else { Beep.play(); return false }
        _ = VectorEditing.newShapeLayer(d, geometry: .path(p), name: "Shape", foregroundFill: true)
        d.commit("New Shape Layer")
        return true
    }
}

// MARK: - Dialogs

struct FillPathDialog: View {
    static let id = "paths2.fill"
    @State private var o = PathOps.FillOptions()
    var body: some View {
        DialogFrame(title: "Fill Path", width: 340, onOK: { if let d = AppActions.doc { PathOps.fill(d, nil, o) } }) {
            Picker("Contents", selection: $o.contents) { ForEach(PathOps.FillContents.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            ValueSlider(label: "Opacity", value: $o.opacity, range: 0...100, unit: "%")
            ValueSlider(label: "Feather", value: $o.feather, range: 0...250, unit: "px", format: "%.1f")
            Toggle2(label: "Anti-alias", on: $o.antialias)
        }
    }
}

struct StrokePathDialog: View {
    static let id = "paths2.stroke"
    @State private var o = PathOps.StrokeOptions()
    var body: some View {
        DialogFrame(title: "Stroke Path", width: 320, onOK: { if let d = AppActions.doc { PathOps.stroke(d, nil, o) } }) {
            Picker("Tool", selection: $o.tool) {
                ForEach(PathOps.strokeTools, id: \.self) { k in Text(k.displayName.replacingOccurrences(of: " Tool", with: "")).tag(k) }
            }
            Toggle2(label: "Simulate Pressure", on: $o.simulatePressure)
            Text("Uses the tool's current brush settings.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}

struct MakeSelectionDialog: View {
    static let id = "paths2.selection"
    @State private var o = PathOps.SelectionOptions()
    var body: some View {
        let hasSel = AppActions.doc?.state.selection != nil
        DialogFrame(title: "Make Selection", width: 320, onOK: { if let d = AppActions.doc { PathOps.makeSelection(d, nil, o) } }) {
            ValueSlider(label: "Feather", value: $o.feather, range: 0...250, unit: "px", format: "%.1f")
            Toggle2(label: "Anti-aliased", on: $o.antialias)
            Picker("Operation", selection: $o.mode) {
                Text("New Selection").tag(SelectionCombine.new)
                Text("Add to Selection").tag(SelectionCombine.add)
                Text("Subtract from Selection").tag(SelectionCombine.subtract)
                Text("Intersect with Selection").tag(SelectionCombine.intersect)
            }
            .disabled(!hasSel)
        }
    }
}

struct MakeWorkPathDialog: View {
    static let id = "paths2.workpath"
    @State private var tolerance: Double = 2
    var body: some View {
        DialogFrame(title: "Make Work Path", width: 300, onOK: { if let d = AppActions.doc { PathOps.makeWorkPath(d, tolerance: tolerance) } }) {
            ValueSlider(label: "Tolerance", value: $tolerance, range: 0.5...10, unit: "px", format: "%.1f")
            Text("From the selection; replaces the Work Path.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}

// MARK: - Paths panel

struct PathsPanelView: View {
    @Bindable var app = AppModel.shared
    @State private var renaming: UUID?
    @State private var text = ""

    var body: some View {
        if let d = app.activeDocument {
            let _ = app.sessionTick
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        if let l = d.activeLayer, let s = l.shape {
                            row(name: "\(l.name) Shape Path", path: s.path, active: d.activePathID == nil, id: nil, d: d)
                        } else if let (l, p) = PathOverlay.typePath(d) {
                            row(name: "\(l.name) Type Path", path: p, active: d.activePathID == nil, id: nil, d: d)
                        }
                        ForEach(d.state.paths) { p in
                            row(name: p.name, path: p.path, active: d.activePathID == p.id, id: p.id, d: d)
                        }
                        // empty space: a click deselects the path (its outline is hidden)
                        Color.clear.frame(height: 80).contentShape(Rectangle())
                            .onTapGesture { renaming = nil; PathOps.deselectPath(d) }
                            .help("Click to deselect the path")
                    }
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                footer(d)
            }
        } else {
            Text("No document").foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func footer(_ d: Document) -> some View {
        let has = PathOps.actionPath(d) != nil
        // (wraps onto a second row in narrow columns instead of being cut off)
        return WrappingHStack(spacing: 2) {
            IconButton(symbol: "circle.fill", help: "Fill path with foreground color") { PathOps.fill(d) }.disabled(!has)
            IconButton(symbol: "circle", help: "Stroke path with brush") { PathOps.stroke(d) }.disabled(!has)
            IconButton(symbol: "circle.dashed", help: "Load path as a selection") { PathOps.makeSelection(d) }.disabled(!has)
            IconButton(symbol: "point.topleft.down.to.point.bottomright.curvepath", help: "Make work path from selection") { PathOps.makeWorkPath(d) }
                .disabled(d.state.selection == nil)
            IconButton(symbol: "rectangle.on.rectangle.circle", help: "Add a vector mask from the path") { PathOps.addVectorMask(d) }.disabled(!has)
            IconButton(symbol: "square.on.circle", help: "Make shape layer from path") { PathOps.makeShape(d) }.disabled(PathOps.actionPath(d, includeShape: false) == nil)
            HStack(spacing: 2) {
                IconButton(symbol: "plus.square", help: "Create new path") { PathOps.newPath(d) }
                IconButton(symbol: "trash", help: "Delete path") { if let id = d.activePathID { PathOps.delete(d, id) } }.disabled(d.activePathID == nil)
                menu(d)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading).padding(.horizontal, 4).background(Theme.panelHeader)
    }

    private func menu(_ d: Document) -> some View {
        let has = PathOps.actionPath(d) != nil
        let active = d.activePathID.flatMap { id in d.state.paths.first { $0.id == id } }
        return Menu {
            Button("New Path") { PathOps.newPath(d) }
            Button("Save Path") { if let id = PathOps.saveWorkPath(d) { startRename(id, d) } }.disabled(active?.name != PathOps.workPathName)
            Button("Duplicate Path") { PathOps.duplicate(d, d.activePathID) }.disabled(!has)
            Button("Delete Path") { if let id = d.activePathID { PathOps.delete(d, id) } }.disabled(active == nil)
            Divider()
            Button("Make Work Path…") { DialogRegistry.show(MakeWorkPathDialog.id) }.disabled(d.state.selection == nil)
            Button("Make Selection…") { DialogRegistry.show(MakeSelectionDialog.id) }.disabled(!has)
            Button("Fill Path…") { DialogRegistry.show(FillPathDialog.id) }.disabled(!has)
            Button("Stroke Path…") { DialogRegistry.show(StrokePathDialog.id) }.disabled(!has)
            Divider()
            Button("Add Vector Mask") { PathOps.addVectorMask(d) }.disabled(!has)
            Button("Make Shape Layer") { PathOps.makeShape(d) }.disabled(PathOps.actionPath(d, includeShape: false) == nil)
            Button("Deselect Path") { PathOps.deselectPath(d) }.disabled(d.activePathID == nil)
        } label: { Image(systemName: "line.3.horizontal") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Paths panel menu")
    }

    private func startRename(_ id: UUID, _ d: Document) {
        text = d.state.paths.first { $0.id == id }?.name ?? ""
        renaming = id
    }

    private func row(name: String, path: VectorPath, active: Bool, id: UUID?, d: Document) -> some View {
        HStack(spacing: 8) {
            PathThumb(path: path, w: d.state.width, h: d.state.height).frame(width: 34, height: 30)
            if let id, renaming == id {
                TextField("", text: $text).textFieldStyle(.plain).font(Theme.font).onSubmit {
                    PathOps.rename(d, id, to: text)
                    renaming = nil
                }
            } else {
                // the temporary Work Path and a shape's own path are in italics, as in Photoshop
                Text(name).font(id == nil || name == PathOps.workPathName ? Theme.font.italic() : Theme.font)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(active ? Theme.selection : Color.clear)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded {
            guard let id else { return }
            if name == PathOps.workPathName { if let nid = PathOps.saveWorkPath(d) { startRename(nid, d) } } else { startRename(id, d) }
        })
        .simultaneousGesture(TapGesture().onEnded {
            if let id { PathOps.selectPath(d, id) } else { PathOps.deselectPath(d) }   // the shape's path is shown with its layer
        })
        .help(id == nil ? "The active layer's own path: a shape's outline or the path of type on a path (Duplicate Path copies it into a saved path)" :
              name == PathOps.workPathName ? "Temporary: the next new path replaces it. Double-click to save it." : "Double-click to rename")
        .contextMenu {
            if let id {
                if name == PathOps.workPathName { Button("Save Path") { if let nid = PathOps.saveWorkPath(d) { startRename(nid, d) } } }
                Button("Duplicate Path") { PathOps.duplicate(d, id) }
                Button("Delete Path") { PathOps.delete(d, id) }
                Divider()
                Button("Make Selection…") { PathOps.selectPath(d, id); DialogRegistry.show(MakeSelectionDialog.id) }
                Button("Fill Path…") { PathOps.selectPath(d, id); DialogRegistry.show(FillPathDialog.id) }
                Button("Stroke Path…") { PathOps.selectPath(d, id); DialogRegistry.show(StrokePathDialog.id) }
                Button("Add Vector Mask") { PathOps.addVectorMask(d, id) }
                Button("Make Shape Layer") { PathOps.makeShape(d, id) }
            } else {
                Button("Duplicate Path") { PathOps.duplicate(d, nil) }
                Button("Make Selection…") { DialogRegistry.show(MakeSelectionDialog.id) }
            }
        }
    }
}
