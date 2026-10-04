import SwiftUI
import AppKit

/// File list shared by Photomerge / Load Files into Stack.
struct SourceList: View {
    @Binding var urls: [URL]
    @Binding var useOpen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Use", selection: $useOpen) { Text("Files").tag(false); Text("Open Documents").tag(true) }.pickerStyle(.segmented).frame(width: 240)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if useOpen {
                        ForEach(AppModel.shared.documents) { d in Text(d.name).lineLimit(1) }
                    } else {
                        ForEach(Array(urls.enumerated()), id: \.offset) { i, u in
                            HStack {
                                Text(u.lastPathComponent).lineLimit(1)
                                Spacer()
                                Button { urls.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            .frame(height: 120)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
            if !useOpen {
                HStack {
                    Button("Browse…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = AppActions.openTypes
                        p.allowsMultipleSelection = true
                        UIBlock.begin(p) { r in if r == .OK { urls += p.urls } }
                    }.buttonStyle(PanelButtonStyle())
                    Button("Add Open Files") { urls += AppModel.shared.documents.compactMap(\.fileURL) }.buttonStyle(PanelButtonStyle())
                    Button("Remove All") { urls = [] }.buttonStyle(PanelButtonStyle())
                }
            }
        }
    }

    func sources() -> [PanoSource] {
        if useOpen { return AppModel.shared.documents.map { MergeActions.source(state: $0.state, name: ($0.name as NSString).deletingPathExtension) } }
        return urls.compactMap { MergeActions.source(url: $0) }
    }

    var count: Int { useOpen ? AppModel.shared.documents.count : urls.count }
}

enum MergeDialogState {
    static var photomergeURLs: [URL] = []
    static var photomerge = PanoOptions()
}

struct PhotomergeDialog: View {
    @State private var urls = MergeDialogState.photomergeURLs
    @State private var useOpen = MergeDialogState.photomergeURLs.isEmpty && AppModel.shared.documents.count >= 2
    @State private var o = MergeDialogState.photomerge

    var body: some View {
        ImagingDialogFrame(title: "Photomerge", width: 560, okDisabled: (useOpen ? AppModel.shared.documents.count : urls.count) < 2, onOK: run) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Caption("Layout")
                    ForEach(PanoLayout.allCases) { l in
                        Button { o.layout = l } label: {
                            HStack { Image(systemName: o.layout == l ? "largecircle.fill.circle" : "circle"); Text(l.rawValue) }
                        }.buttonStyle(.plain)
                    }
                }.frame(width: 130, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Caption("Source Files")
                    SourceList(urls: $urls, useOpen: $useOpen)
                    Toggle2(label: "Blend Images Together", on: $o.blend)
                    Toggle2(label: "Vignette Removal", on: $o.vignette)
                    Toggle2(label: "Geometric Distortion Correction", on: $o.distortion)
                    Toggle2(label: "Content Aware Fill Transparent Areas", on: $o.contentAwareFill)
                    if o.layout == .spherical { Toggle2(label: "360° equirectangular (2:1) output", on: $o.full360) }
                    Picker("Output", selection: $o.asLayers) { Text("Layers with Masks").tag(true); Text("Flattened").tag(false) }.frame(width: 260)
                }
            }
        }
    }

    func run() {
        AppModel.shared.dialog = nil
        MergeDialogState.photomergeURLs = urls
        MergeDialogState.photomerge = o
        let list = SourceList(urls: .constant(urls), useOpen: .constant(useOpen))
        let res = useOpen ? (AppModel.shared.activeDocument?.state.resolution ?? 72) : 72
        let srcs = list.sources()
        guard srcs.count >= 2 else { AppActions.alert("Photomerge needs at least two images."); return }
        MergeActions.photomerge(srcs, options: o, resolution: res)
    }
}

struct AutoAlignDialog: View {
    @State private var layout: PanoLayout = .auto
    @State private var vignette = false
    @State private var distortion = false

    var body: some View {
        ImagingDialogFrame(title: "Auto-Align Layers", width: 360, onOK: {
            AppModel.shared.dialog = nil
            guard let d = AppActions.doc else { return }
            let ok = MergeActions.autoAlign(d, ids: d.orderedSelection, layout: layout, vignette: vignette, distortion: distortion)
            if !ok { AppModel.shared.setStatus("Auto-Align: some layers had no overlapping content and were left in place") }
        }) {
            Caption("Projection")
            ForEach(PanoLayout.allCases) { l in
                Button { layout = l } label: { HStack { Image(systemName: layout == l ? "largecircle.fill.circle" : "circle"); Text(l.rawValue) } }.buttonStyle(.plain)
            }
            Caption("Lens Correction")
            Toggle2(label: "Vignette Removal", on: $vignette)
            Toggle2(label: "Geometric Distortion", on: $distortion)
            Text("Aligns the selected layers to the layer they overlap most.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}

struct AutoBlendDialog: View {
    @State private var method: MergeActions.BlendMethod = .panorama
    @State private var seamless = true

    var body: some View {
        ImagingDialogFrame(title: "Auto-Blend Layers", width: 340, onOK: {
            AppModel.shared.dialog = nil
            guard let d = AppActions.doc else { return }
            MergeActions.autoBlend(d, ids: d.orderedSelection, method: method, seamless: seamless)
        }) {
            Caption("Blend Method")
            ForEach(MergeActions.BlendMethod.allCases) { m in
                Button { method = m } label: { HStack { Image(systemName: method == m ? "largecircle.fill.circle" : "circle"); Text(m.rawValue) } }.buttonStyle(.plain)
            }
            Toggle2(label: "Seamless Tones and Colors", on: $seamless)
            Text(method == .stack ? "Keeps the sharpest areas of each layer (focus stacking)." : "Creates seam masks and balances exposure between overlapping layers.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
    }
}

struct LoadStackDialog: View {
    @State private var urls: [URL] = []
    @State private var useOpen = false
    @State private var align = false
    @State private var smart = false

    var body: some View {
        ImagingDialogFrame(title: "Load Layers", width: 440, okDisabled: (useOpen ? AppModel.shared.documents.count : urls.count) < 1, onOK: {
            AppModel.shared.dialog = nil
            let srcs = SourceList(urls: .constant(urls), useOpen: .constant(useOpen)).sources()
            AppModel.shared.setStatus("Loading \(srcs.count) files into a stack…")
            let al = align, sm = smart
            // runs on the main thread: alignment renders layers through the shared compositor
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let d = MergeActions.loadStack(srcs, align: al, smartObject: sm) else { return }
                AppModel.shared.add(d)
                AppModel.shared.setStatus("Loaded \(srcs.count) layers")
            }
        }) {
            Text("Choose two or more files to load into an image stack.").foregroundStyle(Theme.textDim)
            SourceList(urls: $urls, useOpen: $useOpen)
            Toggle2(label: "Attempt to Automatically Align Source Images", on: $align)
            Toggle2(label: "Create Smart Object after Loading Layers", on: $smart)
        }
    }
}
