import SwiftUI
import AppKit
import ImageCratCore

struct MainView: View {
    @Bindable var app = AppModel.shared
    @Bindable var ws = WorkspaceManager.shared

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                OptionsBar()
                    .frame(height: 36)
                    .background(Theme.panelBG)
                Rectangle().fill(Theme.border).frame(height: 1)
                GeometryReader { g in
                    HStack(spacing: 0) {
                        ToolsPalette()
                            .frame(width: 46)
                            .background(Theme.panelBG)
                        Rectangle().fill(Theme.border).frame(width: 1)
                        VStack(spacing: 0) {
                            DocumentTabs()
                            ZStack {
                                CanvasRepresentable()
                                ContextualTaskBarHost()
                                Workflow2CanvasOverlay()
                                if app.documents.isEmpty { WelcomeView() }
                            }
                            if TimelineController.shared.isPanelVisible { TimelinePanel() }
                            StatusBar()
                        }
                        if app.showPanels {
                            // docked panel columns (AppKit: resizable, drag-and-drop docking; see DockViews.swift)
                            DockArea(showSecondary: app.showSecondaryPanels, theme: app.prefs.theme)
                                .frame(width: dockWidth(g.size.width))
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
            }
            DialogOverlay()
        }
        .background(Theme.appBG)
        .preferredColorScheme(Theme.colorScheme)
        .environment(\.colorScheme, Theme.colorScheme)
    }

    /// The docked columns' width, leaving the canvas at least `DockMetrics.minCanvasWidth` (columns squeeze beyond that).
    private func dockWidth(_ total: CGFloat) -> CGFloat {
        let w = app.showSecondaryPanels ? ws.dockWidthAll : ws.dockWidthPrimary
        return max(0, min(w, total - DockMetrics.toolsWidth - DockMetrics.minCanvasWidth))
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    @Bindable var app = AppModel.shared

    func makeNSView(context: Context) -> CanvasView {
        let v = CanvasView(frame: .zero)
        AppActions.canvas = v
        return v
    }

    func updateNSView(_ v: CanvasView, context: Context) {
        let d = app.activeDocument
        if v.document !== d {
            v.currentTool.commit()
            v.document = d
        }
        _ = d?.revision
        v.setNeedsRender()
    }
}

struct DocumentTabs: View {
    @Bindable var app = AppModel.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(app.documents) { d in
                    DocTab(doc: d, active: d.id == app.activeDocumentID)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 28)
        .background(Theme.panelHeader)
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .bottom)
    }
}

struct DocTab: View {
    let doc: Document
    let active: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Button { AppModel.shared.activeDocumentID = doc.id } label: {
                Text(tr(title)).font(Theme.font).foregroundStyle(active ? Theme.text : Theme.textDim).lineLimit(1)
                    .frame(height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { AppActions.closeDocument(doc) } label: {
                Image(systemName: doc.isDirty && !hover ? "circle.fill" : "xmark")
                    .font(.system(size: doc.isDirty && !hover ? 6 : 8, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 14, height: 14)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(active ? Theme.panelBG : Color.clear)
        .overlay(Rectangle().fill(active ? Theme.accent : .clear).frame(height: 2), alignment: .top)
        .overlay(Rectangle().fill(Theme.border).frame(width: 1), alignment: .trailing)
        .onHover { hover = $0 }
    }

    var title: String {
        let layerName = doc.activeLayer?.name ?? ""
        return "\(doc.name) @ \(ZoomMath.format(doc.zoom)) (\(layerName), \(tr(doc.state.colorMode.short))/\(doc.state.bitDepth.rawValue)\(doc.proofColors && doc.state.colorMode != .cmyk ? "/Proof" : ""))"
    }
}

struct StatusBar: View {
    @Bindable var app = AppModel.shared
    /// Fixed chip values for snapshot tests.
    var preview: StatusBarPreview? = nil

    var body: some View {
        GeometryReader { g in
            let tier = StatusBarTier(width: g.size.width)
            HStack(spacing: tier == .narrow ? 8 : 12) {
                if let d = app.activeDocument {
                    ZoomControl(doc: d, showSlider: g.size.width > 700)   // (the slider goes first when the bar gets narrow)
                        .layoutPriority(3)
                    StatusChip(spec: StatusChips.documentInfo(d), tier: tier).layoutPriority(2)
                    if tier != .narrow, let p = app.cursorDocPoint {
                        StatusChip(spec: StatusChips.cursor(ArtboardCoords.display(p, d)), tier: tier).layoutPriority(1)   // (from the active artboard's corner)
                    }
                    if tier != .narrow, let b = d.state.selectionBounds {
                        StatusChip(spec: StatusChips.selection(b.width, b.height), tier: tier).layoutPriority(1)
                    }
                }
                Spacer(minLength: 6)
                // the least important text: truncates first, then disappears
                Text(tr(app.statusMessage)).font(Theme.font).foregroundStyle(Theme.textDim).lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: 0).layoutPriority(-1)
                    .help(tr(app.statusMessage))
                StatusBarChips(tier: tier, preview: preview)
            }
            .padding(.leading, 6).padding(.trailing, 10)
            .frame(width: g.size.width, height: g.size.height)
        }
        .frame(height: 24)
        .background(Theme.panelHeader)
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .top)
    }
}

struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 22) {
            if AppInfo.isAppBundle, let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
            } else {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(LinearGradient(colors: [Color(red: 0.4, green: 0.7, blue: 1), Color(red: 0.7, green: 0.4, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            Text(tr(Brand.name)).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.text)
            Text("Layers · Smart Objects · Layer Styles · Filters · Vectors").font(Theme.font).foregroundStyle(Theme.textDim)
            HStack(spacing: 12) {
                Button("New File…") { AppModel.shared.dialog = .newDocument }.buttonStyle(PanelButtonStyle(prominent: true))
                Button("Open…") { AppActions.openPanel() }.buttonStyle(PanelButtonStyle())
            }
            let recents = NSDocumentController.shared.recentDocumentURLs.prefix(6)
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("Recent")
                    ForEach(Array(recents), id: \.self) { u in
                        Button { AppActions.open(url: u) } label: {
                            HStack {
                                Image(systemName: "photo").foregroundStyle(Theme.textDim)
                                Text(u.lastPathComponent).font(Theme.font).foregroundStyle(Theme.text)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .padding(14)
                .frame(width: 320, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panelBG))
            }
            Text("Drop images here to open them").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.appBG)
    }
}
