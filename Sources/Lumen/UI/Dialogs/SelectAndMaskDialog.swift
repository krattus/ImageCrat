import SwiftUI
import ImageCratCore

struct SelectAndMaskDialog: View {
    @State private var s = RefineSettings()
    @State private var hasSelection = true
    @State private var hairMask: PixelBuffer?   // Refine Hair result (ObjectSelectionModule)

    var body: some View {
        DialogFrame(title: "Select and Mask", width: 360, onOK: apply, onCancel: cleanup) {
            if !hasSelection {
                Text("No selection — the whole layer is used. Make a selection first for best results.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            Caption("View Mode")
            Picker("View", selection: $s.viewMode) { ForEach(RefineViewMode.allCases) { Text(tr($0.rawValue)).tag($0) } }
            if s.viewMode == .onionSkin || s.viewMode == .overlay {
                ValueSlider(label: "Opacity", value: $s.opacity, range: 0...100, unit: "%")
            }
            Caption("Edge Detection")
            ValueSlider(label: "Radius", value: $s.radius, range: 0...250, unit: "px")
            Toggle2(label: "Smart Radius", on: $s.smartRadius)
            RefineHairButton(hairMask: $hairMask, onChange: updatePreview)
            Caption("Global Refinements")
            ValueSlider(label: "Smooth", value: $s.smooth, range: 0...100)
            ValueSlider(label: "Feather", value: $s.feather, range: 0...250, unit: "px", format: "%.1f")
            ValueSlider(label: "Contrast", value: $s.contrast, range: 0...100, unit: "%")
            ValueSlider(label: "Shift Edge", value: $s.shiftEdge, range: -100...100, unit: "%")
            Caption("Output Settings")
            Toggle2(label: "Decontaminate Colors", on: $s.decontaminate)
            if s.decontaminate { ValueSlider(label: "Amount", value: $s.decontaminateAmount, range: 0...100, unit: "%") }
            Picker("Output To", selection: $s.output) { ForEach(RefineOutput.allCases) { Text(tr($0.rawValue)).tag($0) } }
        }
        .onAppear { hasSelection = AppActions.doc?.state.selection != nil; updatePreview() }
        .onChange(of: s) { _, _ in updatePreview() }
    }

    private func sourceMask(_ d: Document) -> CIImage {
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        if let h = hairMask { return h.ciImage }
        if let sel = d.state.selection { return sel.ciImage }
        return CIImage.color(.white, space.ciCanvas)
    }

    private func updatePreview() {
        guard let d = AppActions.doc else { return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let mask = sourceMask(d)
        let guide = Compositor.shared.composite(d.state)
        let layerImg = d.activeLayer.flatMap { Compositor.shared.contentImage($0, space: space) }?.cropped(to: space.ciCanvas) ?? guide
        let settings = s
        let refined = MaskRefiner.refine(mask: mask, image: guide, canvas: space.ciCanvas, s: settings).insertingIntermediate(cache: true)
        var shown = layerImg
        if settings.decontaminate { shown = MaskRefiner.decontaminate(image: layerImg, mask: refined, canvas: space.ciCanvas, amount: settings.decontaminateAmount) }
        let finalShown = shown
        d.showSelectionEdges = settings.viewMode == .marchingAnts
        d.displayOverride = { comp in MaskRefiner.preview(composite: comp, layerImage: finalShown, mask: refined, canvas: space.ciCanvas, s: settings) }
        d.setNeedsRender()
    }

    private func cleanup() {
        guard let d = AppActions.doc else { return }
        d.displayOverride = nil
        d.showSelectionEdges = true
        d.setNeedsRender()
    }

    private func apply() {
        guard let d = AppActions.doc else { return }
        cleanup()
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let refined = MaskRefiner.refine(mask: sourceMask(d), image: Compositor.shared.composite(d.state), canvas: space.ciCanvas, s: s)
        let buf = RenderEngine.renderBuffer(refined, docRect: d.state.canvasRect, space: space, format: .gray)
        AppActions.applyRefinedSelection(buf, settings: s)
    }
}
