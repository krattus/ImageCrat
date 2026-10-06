import SwiftUI
import AppKit
import CoreImage
import ImageCratCore

/// Frame-animation Timeline, shown as a strip under the canvas (Window > Timeline).
struct TimelinePanel: View {
    @Bindable var app = AppModel.shared
    @Bindable var tl = TimelineController.shared

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            header
            if let d = app.activeDocument {
                if d.state.videoTimeline != nil {
                    VideoTimelineView(doc: d)
                } else if d.state.frames.isEmpty {
                    emptyState(d)
                } else {
                    strip(d)
                    toolbar(d)
                }
            } else {
                Text("No document").font(Theme.font).foregroundStyle(Theme.textFaint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: app.activeDocument?.state.videoTimeline != nil ? 250 : 176)
        .background(Theme.panelBG)
        .onChange(of: app.activeDocumentID) { _, _ in tl.stop(); VideoTimelineController.shared.stop() }
        .onChange(of: app.activeDocument?.revision) { _, _ in
            if let d = app.activeDocument { tl.resync(d) }
        }
        .onAppear { TimelineController.install() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Timeline").font(Theme.fontBold).foregroundStyle(Theme.text)
            Spacer()
            if let d = app.activeDocument {
                Menu {
                    Button("New Frame") { tl.newFrame(d) }
                    Button("Delete Frame") { tl.deleteFrame(d) }.disabled(d.state.frames.isEmpty)
                    Button("Delete Animation") { tl.deleteAnimation(d) }.disabled(d.state.frames.isEmpty)
                    Divider()
                    Button("Tween…") { tl.showTweenDialog(d) }.disabled(d.state.frames.count < 2)
                    Button("Reverse Frames") { tl.reverseFrames(d) }.disabled(d.state.frames.count < 2)
                    Divider()
                    Button("Make Frames From Layers") { tl.makeFramesFromLayers(d) }
                    Button("Convert to Video Timeline") { VideoTimelineController.shared.createTimeline(d) }
                    Menu("Set Delay for All Frames") {
                        ForEach(Animation.delayPresets, id: \.self) { v in
                            Button(tr(Animation.delayLabel(v))) { tl.setDelayForAll(d, v) }
                        }
                    }.disabled(d.state.frames.isEmpty)
                    Divider()
                    Button("Export Animated GIF…") { AnimationExport.exportGIFPanel() }
                    Button("Render Video…") { AnimationExport.exportVideoPanel() }
                    Divider()
                    Button("Close") { tl.stop(); tl.isPanelVisible = false }
                } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Theme.textDim)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Button { tl.stop(); tl.isPanelVisible = false } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textFaint)
            }.buttonStyle(.plain).help("Close Timeline")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.panelHeader)
    }

    private func emptyState(_ d: Document) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button("Create Frame Animation") { tl.createAnimation(d) }.buttonStyle(PanelButtonStyle(prominent: true))
                Button("Make Frames From Layers") { tl.makeFramesFromLayers(d) }.buttonStyle(PanelButtonStyle())
                Button("Create Video Timeline") { VideoTimelineController.shared.createTimeline(d) }.buttonStyle(PanelButtonStyle())
            }
            Text("Frames record layer visibility, position and opacity.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func strip(_ d: Document) -> some View {
        let sel = tl.isPlaying ? tl.playIndex : (tl.selectedIndex(d) ?? 0)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 6) {
                    ForEach(Array(d.state.frames.enumerated()), id: \.element.id) { i, f in
                        TimelineFrameCell(doc: d, frame: f, index: i, selected: i == sel)
                            .id(f.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: sel) { _, s in
                if d.state.frames.indices.contains(s) { proxy.scrollTo(d.state.frames[s].id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toolbar(_ d: Document) -> some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(AnimationLoop.allCases, id: \.self) { l in
                    Button { tl.setLoop(d, l) } label: {
                        if l == d.state.animationLoop { Label(tr(l.rawValue), systemImage: "checkmark") } else { Text(tr(l.rawValue)) }
                    }
                }
            } label: {
                Text(tr(d.state.animationLoop.rawValue)).font(Theme.font).foregroundStyle(Theme.text)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Looping options")
            Rectangle().fill(Theme.divider).frame(width: 1, height: 16).padding(.horizontal, 4)
            IconButton(symbol: "backward.end.fill", help: "Select first frame") { tl.first(d) }
            IconButton(symbol: "backward.frame.fill", help: "Select previous frame") { tl.previous(d) }
            IconButton(symbol: tl.isPlaying ? "stop.fill" : "play.fill", help: tl.isPlaying ? "Stop animation" : "Play animation") { tl.togglePlay(d) }
            IconButton(symbol: "forward.frame.fill", help: "Select next frame") { tl.next(d) }
            Rectangle().fill(Theme.divider).frame(width: 1, height: 16).padding(.horizontal, 4)
            IconButton(symbol: "rectangle.stack.badge.plus", help: "Tween animation frames") { tl.showTweenDialog(d) }
            IconButton(symbol: "plus.square.on.square", help: "Duplicate selected frame") { tl.newFrame(d) }
            IconButton(symbol: "trash", help: "Delete selected frame") { tl.deleteFrame(d) }
            Spacer()
            Text("\(d.state.frames.count) frame\(d.state.frames.count == 1 ? "" : "s") · \(String(format: "%.2f", totalDuration(d))) s")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(Theme.panelHeader)
    }

    private func totalDuration(_ d: Document) -> Double { d.state.frames.reduce(0) { $0 + $1.delay } }
}

struct TimelineFrameCell: View {
    let doc: Document
    let frame: AnimationFrame
    let index: Int
    let selected: Bool
    @Bindable var tl = TimelineController.shared

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("\(index + 1)").font(Theme.fontSmall).foregroundStyle(selected ? Color.white : Theme.textDim)
                Spacer()
            }
            .padding(.horizontal, 4)
            ZStack {
                Checkerboard()
                if let img = FrameThumbnails.shared.image(doc: doc, frame: frame, height: 64) {
                    Image(decorative: img, scale: 2).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: thumbWidth, height: 64)
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { tl.select(doc, index) }
            delayMenu
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.selection : Color(white: 0.23)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1))
    }

    private var thumbWidth: CGFloat {
        let a = CGFloat(doc.state.width) / CGFloat(max(1, doc.state.height))
        return min(128, max(40, 64 * a))
    }

    private var delayMenu: some View {
        Menu {
            ForEach(Animation.delayPresets, id: \.self) { v in
                Button(tr(Animation.delayLabel(v))) { tl.setDelay(doc, index: index, v) }
            }
            Divider()
            Button("Other…") {
                if let v = TimelineController.askDelay(current: frame.delay) { tl.setDelay(doc, index: index, v) }
            }
        } label: {
            Text(tr(Animation.delayLabel(frame.delay))).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Frame delay")
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 6
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.8)))
            var y: CGFloat = 0, r = 0
            while y < size.height {
                var x: CGFloat = (r % 2 == 0) ? 0 : s
                while x < size.width {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(Color(white: 0.62)))
                    x += 2 * s
                }
                y += s; r += 1
            }
        }
    }
}

/// Small cache of rendered frame previews (invalidated by document revision and frame contents).
final class FrameThumbnails {
    static let shared = FrameThumbnails()
    private var cache: [UUID: (doc: UUID, revision: Int, frame: AnimationFrame, height: CGFloat, image: CGImage)] = [:]

    func image(doc: Document, frame: AnimationFrame, height: CGFloat) -> CGImage? {
        if let c = cache[frame.id], c.doc == doc.id, c.revision == doc.revision, c.frame == frame, c.height == height { return c.image }
        if cache.count > 400 { cache.removeAll() }
        // Render from the committed state so playback (uncommitted) never affects previews.
        let base = doc.committedState
        let st = Animation.applied(frame, to: base)
        let space = CanvasSpace(width: st.width, height: st.height)
        let img = Compositor.shared.composite(st)
        let px = height * 2
        let s = px / CGFloat(max(1, st.height))
        let w = max(1, CGFloat(st.width) * s), h = max(1, CGFloat(st.height) * s)
        let scaled = img.cropped(to: space.ciCanvas).transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
        guard let cg = RenderEngine.readbackContext.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: sRGBSpace) else { return nil }
        cache[frame.id] = (doc.id, doc.revision, frame, height, cg)
        return cg
    }
}
