import AppKit
import SwiftUI
import CoreImage
import Observation
import ImageCratCore

enum CompareSource: Equatable {
    case original               // first history state
    case previous               // the step before the current one
    case historyEntry(UUID)
    case snapshot(UUID)
    case version(UUID)
    case branch(UUID)
}

enum CompareLayout: String, CaseIterable, Identifiable {
    case split = "Split", sideBySide = "Side by Side", difference = "Difference", onion = "Onion Skin"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .split: return "rectangle.split.2x1"
        case .sideBySide: return "rectangle.on.rectangle"
        case .difference: return "circle.lefthalf.filled"
        case .onion: return "square.2.layers.3d"
        }
    }
}

/// View ▸ Compare: shows a reference state against the live canvas through `Document.displayOverride`.
/// View-only: nothing is recorded in history, and everything is undone on exit / tool switch / document switch.
@Observable
final class CompareController: @unchecked Sendable {     // main-thread only; Sendable for the observation callback
    static let shared = CompareController()

    private(set) var docID: UUID?
    @ObservationIgnored private weak var doc: Document?
    private(set) var label = ""
    var layout: CompareLayout = .split { didSet { doc?.setNeedsRender() } }
    /// Divider position as a fraction of the document width (split) — also the onion-skin opacity.
    var split: Double = 0.5 { didSet { doc?.setNeedsRender() } }

    @ObservationIgnored private var referenceState: DocumentState?
    @ObservationIgnored private var reference: (w: Int, h: Int, image: CIImage)?
    @ObservationIgnored private var previousOverride: ((CIImage) -> CIImage)?
    @ObservationIgnored private var generation = 0

    var isActive: Bool { docID != nil }
    func isActive(for d: Document?) -> Bool { d != nil && d?.id == docID }

    // MARK: Sources

    static func resolve(_ source: CompareSource, in d: Document) -> (DocumentState, String)? {
        switch source {
        case .original:
            // the first snapshot is the state the document was opened with, even after history has scrolled past it
            if let s = SnapshotStore.shared.snapshots(d).first { return (s.state, "Original") }
            return d.history.first.map { ($0.state, "Original") }
        case .previous:
            guard d.historyIndex > 0 else { return nil }
            let h = d.history[d.historyIndex - 1]
            return (h.state, "Before “\(d.history[d.historyIndex].name)”")
        case .historyEntry(let id):
            return d.history.first { $0.id == id }.map { ($0.state, "History: \($0.name)") }
        case .snapshot(let id):
            return SnapshotStore.shared.snapshots(d).first { $0.id == id }.map { ($0.state, "Snapshot: \($0.name)") }
        case .version(let id):
            guard let v = VersionStore.shared.versions(d).first(where: { $0.id == id }), let st = VersionStore.shared.state(of: id) else { return nil }
            return (st, "Version: \(v.name)")
        case .branch(let id):
            guard let b = HistoryTree.shared.branches(d).first(where: { $0.id == id }), let st = b.entries.last?.state else { return nil }
            return (st, "Branch: \(b.name)")
        }
    }

    // MARK: Lifecycle

    @discardableResult
    func start(_ d: Document, source: CompareSource, layout: CompareLayout? = nil) -> Bool {
        guard let (st, name) = CompareController.resolve(source, in: d) else { Beep.play(); return false }
        return start(d, reference: st, label: name, layout: layout)
    }

    @discardableResult
    func start(_ d: Document, reference st: DocumentState, label: String, layout: CompareLayout? = nil) -> Bool {
        QuickCompare.end()
        if isActive { exit() }
        doc = d
        docID = d.id
        self.label = label
        referenceState = st
        reference = nil
        if let l = layout { self.layout = l }
        previousOverride = d.displayOverride
        d.displayOverride = { [weak self, weak d] comp in
            guard let self, let d else { return comp }
            return self.compose(self.previousOverride?(comp) ?? comp, doc: d)
        }
        d.setNeedsRender()
        watch()
        return true
    }

    func exit() {
        guard isActive else { return }
        generation += 1
        if let d = doc {
            d.displayOverride = previousOverride
            d.setNeedsRender()
        }
        previousOverride = nil
        referenceState = nil
        reference = nil
        doc = nil
        docID = nil
    }

    /// Something else (a dialog preview) replaced or cleared the display override: compare is no longer showing.
    func validate() {
        if isActive, let d = doc, d.displayOverride == nil { exit() }
        if isActive, doc == nil { exit() }
    }

    /// Leaves compare mode as soon as the tool or the active document changes.
    private func watch() {
        generation += 1
        let gen = generation
        withObservationTracking {
            _ = AppModel.shared.tool
            _ = AppModel.shared.activeDocumentID
        } onChange: { [weak self] in
            guard let self, self.generation == gen else { return }
            if Thread.isMainThread { self.exit() } else { DispatchQueue.main.async { if self.generation == gen { self.exit() } } }
        }
    }

    // MARK: Rendering

    /// Reference composite materialised at the document's current canvas size (aspect-fitted when the sizes differ).
    private func referenceImage(w: Int, h: Int) -> CIImage? {
        if let r = reference, r.w == w, r.h == h { return r.image }
        guard let st = referenceState else { return nil }
        let sp = CanvasSpace(width: st.width, height: st.height)
        var img = ImagingDisplay.inks(Compositor.shared.composite(st), state: st).cropped(to: sp.ciCanvas)
        if st.width != w || st.height != h {
            let s = min(CGFloat(w) / CGFloat(st.width), CGFloat(h) / CGFloat(st.height))
            let tx = (CGFloat(w) - CGFloat(st.width) * s) / 2, ty = (CGFloat(h) - CGFloat(st.height) * s) / 2
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: tx, y: ty)), highQualityDownsample: s < 1)
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let out: CIImage
        if let cg = RenderEngine.readbackContext.createCGImage(img.composited(over: CIImage.clearImage.cropped(to: rect)), from: rect, format: .RGBA8, colorSpace: sRGBSpace) {
            out = CIImage(cgImage: cg, options: [.colorSpace: sRGBSpace])
        } else { out = img }
        reference = (w, h, out)
        return out
    }

    func compose(_ comp: CIImage, doc d: Document) -> CIImage {
        let w = d.state.width, h = d.state.height
        guard let ref = referenceImage(w: w, h: h) else { return comp }
        return CompareController.compose(before: ref, after: comp, width: w, height: h, layout: layout, split: split)
    }

    /// Pure image maths (also used by the self test). CI space, canvas at the origin.
    static func compose(before: CIImage, after: CIImage, width w: Int, height h: Int, layout: CompareLayout, split: Double) -> CIImage {
        let W = CGFloat(w), H = CGFloat(h)
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let t = CGFloat(clamp(split, 0, 1))
        switch layout {
        case .split:
            let x = (W * t).rounded()
            let left = before.cropped(to: CGRect(x: 0, y: 0, width: x, height: H))
            let right = after.cropped(to: CGRect(x: x, y: 0, width: W - x, height: H))
            return left.composited(over: right)
        case .sideBySide:
            let s = CGAffineTransform(scaleX: 0.5, y: 0.5)
            let l = before.cropped(to: canvas).transformed(by: s.concatenating(CGAffineTransform(translationX: 0, y: H / 4)), highQualityDownsample: true)
            let r = after.cropped(to: canvas).transformed(by: s.concatenating(CGAffineTransform(translationX: W / 2, y: H / 4)), highQualityDownsample: true)
            return l.composited(over: r).cropped(to: canvas)
        case .difference:
            let white = CIImage.color(.white, canvas)
            let a = after.cropped(to: canvas).composited(over: white), b = before.cropped(to: canvas).composited(over: white)
            return a.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: b]).cropped(to: canvas)
        case .onion:
            return after.cropped(to: canvas).applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: before.cropped(to: canvas), kCIInputTimeKey: t])
                .cropped(to: canvas)
        }
    }
}

// MARK: - Quick compare (hold "\")

/// Hold "\" to see the original (first history state); release to return. View-only.
enum QuickCompare {
    private static weak var doc: Document?
    private static var saved: ((CIImage) -> CIImage)?
    private static var timer: Timer?
    private(set) static var isActive = false
    /// Bumped for the on-canvas badge.
    static var onChange: (() -> Void)?

    static func begin(_ d: Document, keyCode: UInt16? = nil) {
        guard !isActive, let (st, _) = CompareController.resolve(.original, in: d) else { return }
        isActive = true
        doc = d
        saved = d.displayOverride
        let w = d.state.width, h = d.state.height
        let sp = CanvasSpace(width: st.width, height: st.height)
        var img = ImagingDisplay.inks(Compositor.shared.composite(st), state: st).cropped(to: sp.ciCanvas)
        if st.width != w || st.height != h {
            let s = min(CGFloat(w) / CGFloat(st.width), CGFloat(h) / CGFloat(st.height))
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: (CGFloat(w) - CGFloat(st.width) * s) / 2, y: (CGFloat(h) - CGFloat(st.height) * s) / 2)))
        }
        let shown = img
        d.displayOverride = { _ in shown }
        d.setNeedsRender()
        onChange?()
        // Safety net: if the key-up never arrives (focus moved), stop when the key is no longer down.
        if let k = keyCode {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
                if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(k)) { end() }
            }
        }
    }

    static func end() {
        guard isActive else { return }
        isActive = false
        timer?.invalidate(); timer = nil
        if let d = doc {
            d.displayOverride = saved
            d.setNeedsRender()
        }
        saved = nil
        doc = nil
        onChange?()
    }
}

/// Keys routed from `KeyRouter` (only reached when no text field / dialog has the keyboard).
enum Workflow2Keys {
    static func handle(_ e: NSEvent) -> Bool {
        guard e.charactersIgnoringModifiers == "\\" else {
            if e.type == .keyDown, QuickCompare.isActive { QuickCompare.end() }
            return false
        }
        guard !e.modifierFlags.contains(.shift) else { return false }
        if e.type == .keyUp { QuickCompare.end(); return true }
        if e.isARepeat { return true }
        guard let d = AppActions.doc, !CompareController.shared.isActive(for: d) else { return true }
        QuickCompare.begin(d, keyCode: e.keyCode)
        return true
    }
}

// MARK: - Isolate selected layers

/// "Isolate Selected Layers": hides (or dims) every other layer without touching the document — no history step,
/// nothing saved. Uses `Document.hiddenLayers` / `contentOverrides`, which the compositor already honours.
@Observable
final class IsolateMode {
    static let shared = IsolateMode()

    private(set) var docID: UUID?
    @ObservationIgnored private weak var doc: Document?
    private(set) var kept: Set<UUID> = []
    @ObservationIgnored private var applied: Set<UUID> = []
    var dim = false { didSet { if dim != oldValue { reapply() } } }

    func isActive(for d: Document?) -> Bool { d != nil && d?.id == docID }
    var isActive: Bool { docID != nil }

    /// Layers that stay visible for a selection: the layers, everything inside them, their ancestors and clipping bases.
    static func keepSet(_ st: DocumentState, selection: Set<UUID>) -> Set<UUID> {
        var keep: Set<UUID> = []
        func walk(_ layers: [Layer], ancestors: [UUID], inherited: Bool) -> Bool {
            var any = false
            for (i, l) in layers.enumerated() {
                let selected = inherited || selection.contains(l.id)
                var inside = false
                if l.isGroup { inside = walk(l.children, ancestors: ancestors + [l.id], inherited: selected) }
                if selected || inside {
                    keep.insert(l.id)
                    any = true
                    if l.isClipped {   // keep the clipping base so the layer still renders
                        var j = i - 1
                        while j >= 0 { if !layers[j].isClipped { keep.insert(layers[j].id); break }; j -= 1 }
                    }
                }
            }
            if any { keep.formUnion(ancestors) }
            return any
        }
        _ = walk(st.layers, ancestors: [], inherited: false)
        return keep
    }

    func toggle(_ d: Document) {
        if isActive(for: d) { exit() } else { enter(d) }
    }

    @discardableResult
    func enter(_ d: Document) -> Bool {
        if isActive { exit() }
        let sel = d.selectedLayerIDs.isEmpty ? Set(d.activeLayerID.map { [$0] } ?? []) : d.selectedLayerIDs
        let keep = IsolateMode.keepSet(d.state, selection: sel)
        guard !keep.isEmpty else { Beep.play(); return false }
        doc = d
        docID = d.id
        kept = keep
        apply()
        return true
    }

    func exit() {
        guard isActive else { return }
        unapply()
        doc?.setNeedsRender()
        doc = nil
        docID = nil
        kept = []
    }

    /// Re-applies after undo / redo (which reset the document's live-preview state) or a layer change.
    func refresh() {
        guard let d = doc else { if docID != nil { docID = nil; kept = [] }; return }
        let others = Set(d.state.allLayers.map(\.id)).subtracting(kept)
        let ok = dim ? others.allSatisfy { d.contentOverrides[$0] != nil || d.state.layer($0)?.isGroup == true || d.state.layer($0)?.isAdjustment == true }
                     : others.isSubset(of: d.hiddenLayers)
        if !ok { apply() }
    }

    private func reapply() {
        guard isActive else { return }
        unapply()
        apply()
    }

    private func apply() {
        guard let d = doc else { return }
        let others = Set(d.state.allLayers.map(\.id)).subtracting(kept)
        applied = others
        if dim {
            for id in others {
                guard let l = d.state.layer(id), !l.isGroup else { continue }
                if l.isAdjustment { d.hiddenLayers.insert(id); continue }   // an adjustment can't be dimmed through its content
                d.contentOverrides[id] = { $0.withOpacity(0.12) }
            }
        } else {
            d.hiddenLayers.formUnion(others)
        }
        d.setNeedsRender()
    }

    private func unapply() {
        guard let d = doc else { return }
        d.hiddenLayers.subtract(applied)
        for id in applied { d.contentOverrides.removeValue(forKey: id) }
        applied = []
    }
}

// MARK: - On-canvas controls

/// Compare divider / labels and the Isolate exit pill, drawn over the canvas. Only its controls take mouse events.
struct Workflow2CanvasOverlay: View {
    @Bindable var app = AppModel.shared
    @Bindable var compare = CompareController.shared
    @Bindable var isolate = IsolateMode.shared
    @State private var quickTick = 0

    var body: some View {
        GeometryReader { g in
            if let d = app.activeDocument, let canvas = AppActions.canvas {
                let _ = (d.zoom, d.viewOffset, d.viewRotation, d.revision, quickTick)
                ZStack(alignment: .top) {
                    if compare.isActive(for: d) {
                        if compare.layout == .split { CompareDivider(doc: d, canvas: canvas, compare: compare) }
                        compareLabels(d, canvas, size: g.size)
                    }
                    VStack(spacing: 6) {
                        if compare.isActive(for: d) { ComparePill(compare: compare) }
                        if isolate.isActive(for: d) { IsolatePill(isolate: isolate) }
                        if QuickCompare.isActive { QuickCompareBadge() }
                    }
                    .padding(.top, (d.showRulers ? CanvasView.rulerSize : 0) + 10)
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .top)
                .onChange(of: d.revision) { _, _ in isolate.refresh(); compare.validate() }
            }
        }
        .onAppear { QuickCompare.onChange = { quickTick += 1 } }
        .onChange(of: app.activeDocumentID) { _, _ in
            if compare.isActive, compare.docID != app.activeDocumentID { compare.exit() }
            QuickCompare.end()
        }
    }

    @ViewBuilder func compareLabels(_ d: Document, _ canvas: CanvasView, size: CGSize) -> some View {
        let r = canvas.docToView(d.state.canvasCGRect)
        if compare.layout == .split {
            let y = min(max(r.minY + 14, 60), size.height - 20)
            let mid = canvas.docToView(CGPoint(x: CGFloat(d.state.width) * compare.split, y: 0)).x
            CompareTag(text: "BEFORE").position(x: max(r.minX + 36, min(mid - 36, r.maxX - 36)), y: y).allowsHitTesting(false)
            CompareTag(text: "AFTER").position(x: min(r.maxX - 32, max(mid + 32, r.minX + 32)), y: y).allowsHitTesting(false)
        } else if compare.layout == .sideBySide {
            // the two half-size copies sit in the vertical middle of the canvas
            let y = min(max(r.minY + r.height / 4 - 14, 60), size.height - 20)
            CompareTag(text: "BEFORE").position(x: r.minX + r.width * 0.25, y: y).allowsHitTesting(false)
            CompareTag(text: "AFTER").position(x: r.minX + r.width * 0.75, y: y).allowsHitTesting(false)
        }
    }
}

struct CompareTag: View {
    let text: String
    var body: some View {
        Text(tr(text)).font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

/// Draggable split divider (follows zoom, pan and view rotation).
struct CompareDivider: View {
    let doc: Document
    let canvas: CanvasView
    @Bindable var compare: CompareController

    var body: some View {
        let W = CGFloat(doc.state.width), H = CGFloat(doc.state.height)
        let x = W * compare.split
        let a = canvas.docToView(CGPoint(x: x, y: 0)), b = canvas.docToView(CGPoint(x: x, y: H))
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let drag = DragGesture(minimumDistance: 0, coordinateSpace: .named("w2canvas")).onChanged { v in
            let p = canvas.viewToDoc(v.location)
            compare.split = Double(clamp(p.x / max(1, W), 0, 1))
        }
        ZStack {
            Path { p in p.move(to: a); p.addLine(to: b) }.stroke(Color.black.opacity(0.5), lineWidth: 3).allowsHitTesting(false)
            Path { p in p.move(to: a); p.addLine(to: b) }.stroke(Color.white, lineWidth: 1).allowsHitTesting(false)
            // wide invisible grab strip along the line
            Path { p in p.move(to: a); p.addLine(to: b) }.stroke(Color.white.opacity(0.001), lineWidth: 14).gesture(drag)
            ZStack {
                Circle().fill(Color.white).frame(width: 26, height: 26).shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.black.opacity(0.75))
            }
            .position(mid)
            .gesture(drag)
            .help("Drag to move the divider")
        }
        .coordinateSpace(name: "w2canvas")
    }
}

struct ComparePill: View {
    @Bindable var compare: CompareController

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x1").font(.system(size: 10)).foregroundStyle(Theme.accent)
            Text(tr(compare.label)).font(Theme.fontBold).foregroundStyle(.white).lineLimit(1).frame(maxWidth: 220)
            HStack(spacing: 1) {
                ForEach(CompareLayout.allCases) { l in
                    Button { compare.layout = l } label: {
                        Image(systemName: l.symbol).font(.system(size: 10)).frame(width: 24, height: 18)
                            .foregroundStyle(compare.layout == l ? Color.white : Color(white: 0.7))
                            .background(RoundedRectangle(cornerRadius: 4).fill(compare.layout == l ? Theme.accent : Color.clear))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(tr(l.rawValue))
                }
            }
            if compare.layout == .onion {
                Slider(value: $compare.split, in: 0...1).controlSize(.mini).frame(width: 90).help("Opacity of the reference")
            }
            Button { DialogRegistry.show("w2.compareSource") } label: { Image(systemName: "ellipsis.circle").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(Color(white: 0.8)).help("Choose what to compare with…")
            Button { compare.exit() } label: {
                HStack(spacing: 3) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)); Text("Exit Compare").font(Theme.fontSmall) }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }.buttonStyle(.plain).foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        .fixedSize()
    }
}

struct IsolatePill: View {
    @Bindable var isolate: IsolateMode

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").font(.system(size: 10)).foregroundStyle(Color(red: 1, green: 0.78, blue: 0.3))
            Text("Isolating \(isolate.kept.count) layer\(isolate.kept.count == 1 ? "" : "s")").font(Theme.fontBold).foregroundStyle(.white)
            HStack(spacing: 1) {
                ForEach([false, true], id: \.self) { dim in
                    Button { isolate.dim = dim } label: {
                        Text(tr(dim ? "Dim others" : "Hide others")).font(Theme.fontSmall).padding(.horizontal, 7).frame(height: 18)
                            .foregroundStyle(isolate.dim == dim ? Color.white : Color(white: 0.7))
                            .background(RoundedRectangle(cornerRadius: 4).fill(isolate.dim == dim ? Theme.accent : Color.clear))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Button { isolate.exit() } label: {
                HStack(spacing: 3) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)); Text("Exit Isolation").font(Theme.fontSmall) }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }.buttonStyle(.plain).foregroundStyle(.white)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .overlay(Capsule().stroke(Color(red: 1, green: 0.78, blue: 0.3).opacity(0.6), lineWidth: 0.5))
        .fixedSize()
    }
}

struct QuickCompareBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
            Text("Original").font(Theme.fontBold)
            Text("release \\ to return").font(Theme.fontSmall).foregroundStyle(Color(white: 0.75))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .fixedSize()
        .allowsHitTesting(false)
    }
}

// MARK: - Source chooser

/// View ▸ Compare ▸ Choose Source…: every snapshot, version, branch and history state of the document.
struct CompareSourceDialog: View {
    @State private var layout = CompareController.shared.layout

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare With").font(.system(size: 13, weight: .semibold))
            if let d = AppActions.doc {
                HStack(spacing: 2) {
                    ForEach(CompareLayout.allCases) { l in
                        Button { layout = l } label: {
                            HStack(spacing: 4) { Image(systemName: l.symbol).font(.system(size: 9)); Text(tr(l.rawValue)).font(Theme.fontSmall) }
                                .padding(.horizontal, 7).frame(height: 22)
                                .foregroundStyle(layout == l ? Color.white : Theme.textDim)
                                .background(RoundedRectangle(cornerRadius: 4).fill(layout == l ? Theme.accent : Theme.fieldBG))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        section("Document")
                        row("Original (first state)", "doc") { go(d, .original) }
                        if d.historyIndex > 0 { row("Previous history state", "arrow.uturn.backward") { go(d, .previous) } }
                        let snaps = SnapshotStore.shared.snapshots(d)
                        if !snaps.isEmpty {
                            section("Snapshots")
                            ForEach(snaps) { s in row(s.name, "camera") { go(d, .snapshot(s.id)) } }
                        }
                        let versions = VersionStore.shared.versions(d)
                        if !versions.isEmpty {
                            section("Versions")
                            ForEach(versions.reversed()) { v in row(v.name, "bookmark", detail: Workflow2Util.relativeTime(v.date)) { go(d, .version(v.id)) } }
                        }
                        let branches = HistoryTree.shared.branches(d)
                        if !branches.isEmpty {
                            section("History Branches")
                            ForEach(branches) { b in row(b.name, "arrow.triangle.branch", detail: "\(b.entries.count) step\(b.entries.count == 1 ? "" : "s")") { go(d, .branch(b.id)) } }
                        }
                        section("History States")
                        ForEach(Array(d.history.enumerated().reversed()), id: \.element.id) { i, h in
                            row(h.name, i == d.historyIndex ? "circle.fill" : "circle", detail: i == d.historyIndex ? "current" : "") { go(d, .historyEntry(h.id)) }
                        }
                    }
                }
                .frame(width: 330, height: 300)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fieldBG))
            }
            HStack { Spacer(); Button("Cancel") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction) }
        }
        .padding(.horizontal, 16).padding(.bottom, 14)
        .frame(width: 362, alignment: .leading)
    }

    func section(_ t: String) -> some View {
        Caption(t).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 3)
    }

    func row(_ title: String, _ symbol: String, detail: String = "", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(Theme.textDim).frame(width: 14)
                Text(tr(title)).lineLimit(1)
                Spacer()
                Text(tr(detail)).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 8).frame(height: 22).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    func go(_ d: Document, _ s: CompareSource) {
        AppModel.shared.dialog = nil
        CompareController.shared.start(d, source: s, layout: layout)
    }
}
