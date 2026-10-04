import AppKit
import SwiftUI
import Observation
import AVFoundation
import UniformTypeIdentifiers
import ImageCratCore

// MARK: - Controller

/// Video Timeline state & commands: playhead per document, keyframe editing, playback and
/// recording layer edits as keyframes at the playhead.
@Observable
final class VideoTimelineController {
    static let shared = VideoTimelineController()

    var time: [UUID: Double] = [:]
    var isPlaying = false
    var expanded: Set<UUID> = []
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var playDocID: UUID?
    @ObservationIgnored private var playStart = Date()
    @ObservationIgnored private var playFrom = 0.0
    @ObservationIgnored private static var installed = false

    /// Chains the commit hook after the frame-animation one (keyframes follow edits made at the playhead).
    static func install() {
        guard !installed else { return }
        installed = true
        TimelineController.install()
        let prev = Document.willCommit
        Document.willCommit = { d in
            prev?(d)
            VideoTimelineController.shared.syncKeyframes(d)
        }
    }

    func currentTime(_ d: Document) -> Double { time[d.id] ?? 0 }
    static func isVideoMode(_ d: Document) -> Bool { d.state.videoTimeline != nil }

    // MARK: Mode

    /// Creates a video timeline (converting frame animation frames into hold keyframes).
    func createTimeline(_ d: Document) {
        TimelineController.shared.stop()
        applying = true
        var st = d.state
        let tl = VideoTimelineEngine.timeline(fromFrames: st)
        if let f = st.frames.first { Animation.apply(f, to: &st) }
        st.frames = []
        st.videoTimeline = tl
        d.state = st
        time[d.id] = 0
        d.commit("Create Video Timeline")
        applying = false
        setTime(d, 0)
        TimelineController.shared.isPanelVisible = true
    }

    /// Video timeline → frame animation (sampled at the timeline frame rate, at most 100 frames).
    func convertToFrames(_ d: Document) {
        stop()
        guard d.state.videoTimeline != nil else { return }
        let frames = VideoTimelineEngine.frames(fromTimeline: d.state)
        applying = true
        var st = d.state
        st.videoTimeline = nil
        st.frames = frames
        if let f = frames.first { Animation.apply(f, to: &st) }
        d.state = st
        TimelineController.shared.selection[d.id] = 0
        d.commit("Convert to Frame Animation")
        applying = false
    }

    func deleteTimeline(_ d: Document) {
        stop()
        applying = true
        d.state.videoTimeline = nil
        d.commit("Delete Timeline")
        applying = false
    }

    // MARK: Playhead

    /// Moves the playhead and shows the layers at that time (not a history step).
    func setTime(_ d: Document, _ t: Double, decodeVideo: Bool = true) {
        guard let tl = d.state.videoTimeline else { return }
        let s = tl.snap(t)
        time[d.id] = s
        applying = true
        var st = d.state
        VideoTimelineEngine.apply(at: s, to: &st, decodeVideo: decodeVideo)
        d.state = st
        applying = false
    }

    func step(_ d: Document, _ frames: Int) {
        guard let tl = d.state.videoTimeline else { return }
        setTime(d, currentTime(d) + Double(frames) / tl.frameRate)
    }

    func togglePlay(_ d: Document) { if isPlaying { stop() } else { play(d) } }

    func play(_ d: Document) {
        guard let tl = d.state.videoTimeline else { return }
        stop()
        isPlaying = true
        playDocID = d.id
        playFrom = currentTime(d) >= tl.duration - 1 / tl.frameRate ? 0 : currentTime(d)
        playStart = Date()
        let t = Timer(timeInterval: 1 / max(1, min(60, tl.frameRate)), repeats: true) { [weak self, weak d] _ in
            guard let self, let d, self.isPlaying, let tl = d.state.videoTimeline,
                  AppModel.shared.documents.contains(where: { $0 === d }) else { self?.stop(); return }
            var now = self.playFrom + Date().timeIntervalSince(self.playStart)
            if now >= tl.duration { now = now.truncatingRemainder(dividingBy: max(tl.duration, 0.001)); self.playFrom = now; self.playStart = Date() }
            self.setTime(d, now)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isPlaying = false
        playDocID = nil
    }

    // MARK: Editing

    private func edit(_ d: Document, _ name: String, _ f: (inout VideoTimeline) -> Void) {
        guard var tl = d.state.videoTimeline else { return }
        f(&tl)
        applying = true
        d.state.videoTimeline = tl
        d.commit(name)
        applying = false
        setTime(d, currentTime(d))
    }

    /// Stopwatch: enables keyframing (adds a key at the playhead) or removes all keys of the property.
    func toggleStopwatch(_ d: Document, _ layerID: UUID, _ p: TrackProperty) {
        guard let tl = d.state.videoTimeline, let l = d.state.layer(layerID) else { return }
        let keyed = !(tl.track(layerID)?.keys(p).isEmpty ?? true)
        let value = VideoTimelineEngine.currentValue(p, l, state: d.state)
        edit(d, keyed ? "Disable Keyframes" : "Enable Keyframes") { tl in
            tl.updateTrack(layerID) { tr in
                if keyed { tr.setKeys(p, []) }
                else if let v = value { tr.setKeys(p, [Keyframe(time: currentTime(d), value: v)]) }
            }
        }
    }

    func keyAtPlayhead(_ d: Document, _ layerID: UUID, _ p: TrackProperty) -> Keyframe? {
        guard let tl = d.state.videoTimeline else { return nil }
        let t = currentTime(d)
        return tl.track(layerID)?.keys(p).first { abs($0.time - t) < 0.5 / tl.frameRate }
    }

    /// Adds a keyframe at the playhead with the current value, or removes the one there.
    func toggleKeyframe(_ d: Document, _ layerID: UUID, _ p: TrackProperty) {
        guard let l = d.state.layer(layerID) else { return }
        let existing = keyAtPlayhead(d, layerID, p)
        let value = VideoTimelineEngine.currentValue(p, l, state: d.state)
        let t = currentTime(d)
        edit(d, existing == nil ? "Add Keyframe" : "Delete Keyframe") { tl in
            tl.updateTrack(layerID) { tr in
                var k = tr.keys(p)
                if let e = existing { k.removeAll { $0.id == e.id } }
                else if let v = value { k.append(Keyframe(time: t, value: v)) }
                tr.setKeys(p, k)
            }
        }
    }

    func setInterpolation(_ d: Document, _ layerID: UUID, _ p: TrackProperty, _ keyID: UUID, _ i: KeyInterpolation) {
        edit(d, "Keyframe Interpolation") { tl in
            tl.updateTrack(layerID) { tr in
                var k = tr.keys(p)
                if let j = k.firstIndex(where: { $0.id == keyID }) { k[j].interpolation = i }
                tr.setKeys(p, k)
            }
        }
    }

    func deleteKeyframe(_ d: Document, _ layerID: UUID, _ p: TrackProperty, _ keyID: UUID) {
        edit(d, "Delete Keyframe") { tl in tl.updateTrack(layerID) { tr in tr.setKeys(p, tr.keys(p).filter { $0.id != keyID }) } }
    }

    /// Live (uncommitted) keyframe move; call `commitEdit` when the drag ends.
    func moveKeyframe(_ d: Document, _ layerID: UUID, _ p: TrackProperty, _ keyID: UUID, to t: Double) {
        guard var tl = d.state.videoTimeline else { return }
        let s = tl.snap(t)
        tl.updateTrack(layerID) { tr in
            var k = tr.keys(p)
            if let j = k.firstIndex(where: { $0.id == keyID }) { k[j].time = s }
            tr.setKeys(p, k)
        }
        applying = true
        d.state.videoTimeline = tl
        applying = false
        setTime(d, currentTime(d))
    }

    /// Live (uncommitted) duration-bar change.
    func setTrackRange(_ d: Document, _ layerID: UUID, start: Double, duration: Double) {
        guard var tl = d.state.videoTimeline else { return }
        let fr = 1 / tl.frameRate
        let snapped = tl.snap(start), total = tl.duration, rate = tl.frameRate
        tl.updateTrack(layerID) { tr in
            var st = snapped, du = max(fr, (duration * rate).rounded() / rate)
            if let v = tr.video { du = min(du, v.sourceDuration - v.inPoint) }
            st = min(st, total - fr)
            tr.start = st; tr.duration = du
            if var v = tr.video { v.outPoint = v.inPoint + du; tr.video = v }
        }
        applying = true
        d.state.videoTimeline = tl
        applying = false
        setTime(d, currentTime(d))
    }

    /// Trims the start of a bar (video layers move their in point).
    func trimStart(_ d: Document, _ layerID: UUID, original: LayerTrack, delta: Double) {
        guard var tl = d.state.videoTimeline else { return }
        let fr = 1 / tl.frameRate
        var dt = (delta * tl.frameRate).rounded() / tl.frameRate
        dt = max(dt, -original.start)
        if let v = original.video { dt = max(dt, -v.inPoint) }
        dt = min(dt, original.duration - fr)
        tl.updateTrack(layerID) { tr in
            tr.start = original.start + dt
            tr.duration = original.duration - dt
            if var v = original.video { v.inPoint += dt; tr.video = v }
        }
        applying = true
        d.state.videoTimeline = tl
        applying = false
        setTime(d, currentTime(d))
    }

    func commitEdit(_ d: Document, _ name: String) {
        applying = true
        d.commit(name)
        applying = false
    }

    func setDuration(_ d: Document, _ seconds: Double) {
        edit(d, "Timeline Duration") { tl in
            let old = tl.duration
            tl.duration = seconds.isFinite ? min(max(1 / max(1, tl.frameRate), seconds), 3600) : old
            for i in tl.tracks.indices where tl.tracks[i].video == nil && abs(tl.tracks[i].end - old) < 0.001 && tl.tracks[i].start == 0 {
                tl.tracks[i].duration = tl.duration
            }
        }
    }

    func setFrameRate(_ d: Document, _ fps: Double) { edit(d, "Frame Rate") { $0.frameRate = max(1, min(120, fps)) } }

    // MARK: Commit hook

    /// Edits of keyed properties made at the playhead become keyframes there.
    func syncKeyframes(_ d: Document) {
        guard !applying, !isPlaying, var tl = d.state.videoTimeline else { return }
        let t = currentTime(d)
        var changed = false
        for (ti, tr) in tl.tracks.enumerated() {
            guard let l = d.state.layer(tr.layerID) else { continue }
            for p in TrackProperty.allCases {
                let keys = tr.keys(p)
                guard !keys.isEmpty, let v = VideoTimelineEngine.value(keys, at: t),
                      let cur = VideoTimelineEngine.currentValue(p, l, state: d.state), !Self.close(v, cur) else { continue }
                var k = keys
                if let j = k.firstIndex(where: { abs($0.time - t) < 0.5 / tl.frameRate }) { k[j].value = cur }
                else { k.append(Keyframe(time: t, value: cur)) }
                tl.tracks[ti].setKeys(p, k)
                changed = true
            }
        }
        if changed { d.state.videoTimeline = tl }
    }

    static func close(_ a: KeyValue, _ b: KeyValue) -> Bool {
        switch (a, b) {
        case (.point(let p), .point(let q)): return abs(p.x - q.x) < 0.75 && abs(p.y - q.y) < 0.75
        case (.number(let x), .number(let y)): return abs(x - y) < 0.002
        case (.transform(let s0, let r0), .transform(let s1, let r1)): return abs(s0 - s1) < 0.002 && abs(r0 - r1) < 0.05
        case (.style(let e0), .style(let e1)): return e0 == e1
        default: return false
        }
    }

    // MARK: Dialog helpers

    static func askNumber(_ title: String, _ current: Double) -> Double? {
        let a = NSAlert()
        a.messageText = title
        let f = NSTextField(string: String(format: "%g", current))
        f.frame = NSRect(x: 0, y: 0, width: 120, height: 22)
        a.accessoryView = f
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        guard UIBlock.run(a) == .alertFirstButtonReturn, let v = Double(f.stringValue.replacingOccurrences(of: ",", with: ".")), v.isFinite else { return nil }
        return v
    }

    static func timecode(_ t: Double, fps: Double) -> String {
        let f = Int((t * fps).rounded())
        let fr = Int(fps.rounded())
        let s = f / max(1, fr)
        return String(format: "%02d:%02d:%02d", s / 60, s % 60, f % max(1, fr))
    }
}

// MARK: - Panel

struct VideoTimelineView: View {
    let doc: Document
    @Bindable var vt = VideoTimelineController.shared
    private let labelWidth: CGFloat = 200

    var body: some View {
        let tl = doc.state.videoTimeline ?? VideoTimeline()
        VStack(spacing: 0) {
            toolbar(tl)
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 0) {
                Text(VideoTimelineController.timecode(vt.currentTime(doc), fps: tl.frameRate))
                    .font(Theme.mono).foregroundStyle(Theme.accent).padding(.leading, 8).frame(width: labelWidth, alignment: .leading)
                RulerLane(doc: doc, tl: tl)
            }
            .frame(height: 20)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(doc.state.layers.flattenedForDisplay(includeCollapsed: true).map(\.0), id: \.id) { l in
                        trackRows(l, tl)
                    }
                }
            }
        }
    }

    private func toolbar(_ tl: VideoTimeline) -> some View {
        HStack(spacing: 4) {
            IconButton(symbol: "backward.end.fill", help: "Go to first frame") { vt.setTime(doc, 0) }
            IconButton(symbol: "backward.frame.fill", help: "Previous frame") { vt.step(doc, -1) }
            IconButton(symbol: vt.isPlaying ? "stop.fill" : "play.fill", help: vt.isPlaying ? "Stop" : "Play") { vt.togglePlay(doc) }
            IconButton(symbol: "forward.frame.fill", help: "Next frame") { vt.step(doc, 1) }
            IconButton(symbol: "forward.end.fill", help: "Go to last frame") { vt.setTime(doc, tl.duration - 1 / tl.frameRate) }
            Rectangle().fill(Theme.divider).frame(width: 1, height: 16).padding(.horizontal, 4)
            Menu {
                Button("Duration (\(String(format: "%g", tl.duration)) s)…") {
                    if let v = VideoTimelineController.askNumber("Timeline duration (seconds)", tl.duration) { vt.setDuration(doc, v) }
                }
                Menu("Frame Rate") {
                    ForEach([12.0, 15, 23.976, 24, 25, 29.97, 30, 50, 60], id: \.self) { f in
                        Button(String(format: "%g fps", f)) { vt.setFrameRate(doc, f) }
                    }
                }
                Divider()
                Button("Video to Layer…") { VideoLayerImport.importPanel() }
                Button("Render Video…") { DialogRegistry.show("renderVideo") }
                Divider()
                Button("Convert to Frame Animation") { vt.convertToFrames(doc) }
                Button("Delete Timeline") { vt.deleteTimeline(doc) }
            } label: { Text("\(String(format: "%g", tl.frameRate)) fps · \(String(format: "%.2f", tl.duration)) s").font(Theme.fontSmall) }
                .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            IconButton(symbol: "film", help: "Convert to Frame Animation") { vt.convertToFrames(doc) }
            IconButton(symbol: "square.and.arrow.up", help: "Render Video…") { DialogRegistry.show("renderVideo") }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.panelHeader)
    }

    @ViewBuilder private func trackRows(_ l: Layer, _ tl: VideoTimeline) -> some View {
        let tr = tl.track(l.id) ?? LayerTrack(layerID: l.id, duration: tl.duration)
        let open = vt.expanded.contains(l.id)
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).frame(width: 12)
                    .onTapGesture { if open { vt.expanded.remove(l.id) } else { vt.expanded.insert(l.id) } }
                Image(systemName: tr.video != nil ? "film" : (l.isGroup ? "folder" : (l.isText ? "textformat" : "photo")))
                    .font(.system(size: 10)).foregroundStyle(Theme.textDim)
                Text(l.name).lineLimit(1).font(Theme.font)
                Spacer()
            }
            .padding(.leading, 6).frame(width: labelWidth)
            DurationLane(doc: doc, tl: tl, track: tr, isVideo: tr.video != nil)
        }
        .frame(height: 24)
        .background(Color(white: 0.2))
        if open {
            ForEach(TrackProperty.allCases.filter { VideoTimelineEngine.supports($0, l) }) { p in
                propertyRow(l, p, tr, tl)
            }
        }
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    @ViewBuilder private func propertyRow(_ l: Layer, _ p: TrackProperty, _ tr: LayerTrack, _ tl: VideoTimeline) -> some View {
        let keys = tr.keys(p)
        let atHead = vt.keyAtPlayhead(doc, l.id, p) != nil
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { vt.toggleStopwatch(doc, l.id, p) } label: {
                    Image(systemName: "stopwatch").foregroundStyle(keys.isEmpty ? Theme.textFaint : Theme.accent)
                }.buttonStyle(.plain).help("Enable keyframe animation")
                Text(p.rawValue).font(Theme.fontSmall).foregroundStyle(Theme.textDim)
                Spacer()
                if !keys.isEmpty {
                    Button { vt.toggleKeyframe(doc, l.id, p) } label: {
                        Image(systemName: atHead ? "diamond.fill" : "diamond").font(.system(size: 9)).foregroundStyle(Color.yellow)
                    }.buttonStyle(.plain).help(atHead ? "Remove keyframe at playhead" : "Add keyframe at playhead")
                }
            }
            .padding(.leading, 26).padding(.trailing, 6).frame(width: labelWidth)
            KeyframeLane(doc: doc, tl: tl, layerID: l.id, property: p, keys: keys)
        }
        .frame(height: 20)
        .background(Color(white: 0.17))
    }
}

/// Time ruler with ticks; click / drag moves the playhead.
private struct RulerLane: View {
    let doc: Document
    let tl: VideoTimeline
    @Bindable var vt = VideoTimelineController.shared
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let secs = Int(ceil(tl.duration))
                    let step = max(1, Int(ceil(Double(secs) / max(1, Double(size.width) / 60))))
                    for s in stride(from: 0, through: secs, by: step) {
                        let x = CGFloat(Double(s) / tl.duration) * size.width
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 8)); $0.addLine(to: CGPoint(x: x, y: size.height)) }, with: .color(Theme.textFaint))
                        ctx.draw(Text("\(s)s").font(.system(size: 8)).foregroundColor(Theme.textFaint), at: CGPoint(x: x + 9, y: 5))
                    }
                }
                PlayheadMark(x: CGFloat(vt.currentTime(doc) / max(tl.duration, 0.001)) * w, head: true)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                vt.setTime(doc, Double(v.location.x / max(1, w)) * tl.duration)
            })
        }
        .background(Color(white: 0.15))
    }
}

private struct PlayheadMark: View {
    let x: CGFloat
    var head = false
    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color.red).frame(width: 1)
            if head { Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8)).foregroundStyle(Color.red).offset(y: -2) }
        }
        .frame(width: head ? 9 : 1)
        .offset(x: x - (head ? 4.5 : 0.5))
        .allowsHitTesting(false)
    }
}

/// Duration bar: drag the middle to move, the edges to trim.
private struct DurationLane: View {
    let doc: Document
    let tl: VideoTimeline
    let track: LayerTrack
    let isVideo: Bool
    @Bindable var vt = VideoTimelineController.shared
    @State private var dragOrigin: LayerTrack?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let pps = w / CGFloat(max(tl.duration, 0.001))
            let x0 = CGFloat(track.start) * pps, x1 = CGFloat(track.end) * pps
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(isVideo ? Color(red: 0.45, green: 0.35, blue: 0.7) : Color(red: 0.3, green: 0.45, blue: 0.7))
                    .frame(width: max(4, x1 - x0), height: 16)
                    .offset(x: x0, y: 4)
                    .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                        let o = dragOrigin ?? track
                        if dragOrigin == nil { dragOrigin = track }
                        vt.setTrackRange(doc, track.layerID, start: o.start + Double(v.translation.width / pps), duration: o.duration)
                    }.onEnded { _ in dragOrigin = nil; vt.commitEdit(doc, "Move Layer Duration") })
                // trim handles
                handle.offset(x: x0, y: 4).gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    let o = dragOrigin ?? track
                    if dragOrigin == nil { dragOrigin = track }
                    vt.trimStart(doc, track.layerID, original: o, delta: Double(v.translation.width / pps))
                }.onEnded { _ in dragOrigin = nil; vt.commitEdit(doc, "Trim Layer Start") })
                handle.offset(x: max(x0, x1 - 6), y: 4).gesture(DragGesture(minimumDistance: 1).onChanged { v in
                    let o = dragOrigin ?? track
                    if dragOrigin == nil { dragOrigin = track }
                    vt.setTrackRange(doc, track.layerID, start: o.start, duration: o.duration + Double(v.translation.width / pps))
                }.onEnded { _ in dragOrigin = nil; vt.commitEdit(doc, "Trim Layer End") })
                PlayheadMark(x: CGFloat(vt.currentTime(doc)) * pps)
            }
        }
    }

    private var handle: some View {
        Rectangle().fill(Color.white.opacity(0.35)).frame(width: 6, height: 16).contentShape(Rectangle())
            .onHover { h in if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
    }
}

/// Keyframe diamonds: click to jump, drag to move, context menu for interpolation / delete.
private struct KeyframeLane: View {
    let doc: Document
    let tl: VideoTimeline
    let layerID: UUID
    let property: TrackProperty
    let keys: [Keyframe]
    @Bindable var vt = VideoTimelineController.shared
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { g in
            let pps = g.size.width / CGFloat(max(tl.duration, 0.001))
            ZStack(alignment: .topLeading) {
                // interpolation segments
                ForEach(Array(keys.enumerated()), id: \.element.id) { i, k in
                    if i + 1 < keys.count {
                        Rectangle().fill(k.interpolation == .hold ? Color.gray.opacity(0.5) : Color.yellow.opacity(0.35))
                            .frame(width: max(0, CGFloat(keys[i + 1].time - k.time) * pps), height: k.interpolation == .hold ? 1 : 2)
                            .offset(x: CGFloat(k.time) * pps, y: 9)
                    }
                }
                ForEach(keys) { k in
                    Image(systemName: k.interpolation == .hold ? "square.fill" : (k.interpolation == .ease ? "circle.fill" : "diamond.fill"))
                        .font(.system(size: 9)).foregroundStyle(Color.yellow)
                        .frame(width: 12, height: 20)
                        .offset(x: CGFloat(k.time) * pps - 6)
                        .onTapGesture { vt.setTime(doc, k.time) }
                        .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                            if dragStart == nil { dragStart = k.time }
                            vt.moveKeyframe(doc, layerID, property, k.id, to: dragStart! + Double(v.translation.width / pps))
                        }.onEnded { _ in dragStart = nil; vt.commitEdit(doc, "Move Keyframe") })
                        .contextMenu {
                            ForEach(KeyInterpolation.allCases, id: \.self) { i in
                                Button { vt.setInterpolation(doc, layerID, property, k.id, i) } label: {
                                    if k.interpolation == i { Label(i.rawValue, systemImage: "checkmark") } else { Text(i.rawValue) }
                                }
                            }
                            Divider()
                            Button("Delete Keyframe") { vt.deleteKeyframe(doc, layerID, property, k.id) }
                        }
                }
                PlayheadMark(x: CGFloat(vt.currentTime(doc)) * pps)
            }
        }
    }
}

// MARK: - Video to Layer

enum VideoLayerImport {
    /// Creates a video layer (smart object showing the frame at the playhead) from a movie file.
    @discardableResult
    static func addVideoLayer(_ url: URL, to d: Document, at start: Double = 0) throws -> UUID {
        let info = try VideoFrameCache.probeSync(url)
        let clip = VideoClip(url: url, inPoint: 0, outPoint: info.duration, sourceDuration: info.duration, frameRate: info.fps, naturalSize: info.size)
        guard let first = VideoFrameCache.shared.frame(clip, at: 0) else { throw VideoImportError.noFrames }
        let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
        let k = min(1, min(W / info.size.width, H / info.size.height))
        let r = CGRect(x: (W - info.size.width * k) / 2, y: (H - info.size.height * k) / 2, width: info.size.width * k, height: info.size.height * k)
        var so = SmartObjectContent(source: .image(first), quad: Quad(rect: r), sourceName: url.lastPathComponent)
        so.sourceRevision = SourceRevision.next()
        let layer = Layer(name: (url.lastPathComponent as NSString).deletingPathExtension, content: .smartObject(so))
        var st = d.state
        if let a = d.activeLayerID { st.insertLayer(layer, above: a) } else { st.layers.append(layer) }
        var tl = st.videoTimeline ?? VideoTimelineEngine.timeline(fromFrames: st)
        if st.videoTimeline == nil, let f = st.frames.first { Animation.apply(f, to: &st); st.frames = [] }
        tl.duration = max(tl.duration, start + info.duration)
        if st.videoTimeline == nil && tl.tracks.allSatisfy({ $0.keyframes.isEmpty }) {
            tl.duration = start + info.duration
            for i in tl.tracks.indices { tl.tracks[i].duration = tl.duration }
            tl.frameRate = (info.fps * 1000).rounded() / 1000
        }
        tl.tracks.removeAll { $0.layerID == layer.id }
        tl.tracks.append(LayerTrack(layerID: layer.id, start: start, duration: info.duration, video: clip))
        st.videoTimeline = tl
        d.state = st
        d.activeLayerID = layer.id
        d.selectedLayerIDs = [layer.id]
        d.commit("Video to Layer")
        return layer.id
    }

    static func importPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
        p.message = "Choose a video to add as a video layer"
        guard UIBlock.run(p) == .OK, let url = p.url else { return }
        do {
            let d: Document
            if let a = AppActions.doc { d = a } else {
                let info = try VideoFrameCache.probeSync(url)
                d = Document.newBlank(width: Int(info.size.width), height: Int(info.size.height), background: .black, name: (url.lastPathComponent as NSString).deletingPathExtension)
                AppModel.shared.add(d)
            }
            let start = d.state.videoTimeline != nil ? VideoTimelineController.shared.currentTime(d) : 0
            try addVideoLayer(url, to: d, at: start)
            TimelineController.shared.isPanelVisible = true
            VideoTimelineController.shared.setTime(d, VideoTimelineController.shared.currentTime(d))
        } catch {
            AppActions.alert("Could not import “\(url.lastPathComponent)”.", error.localizedDescription)
        }
    }
}

// MARK: - Render Video dialog

struct RenderVideoDialog: View {
    @State private var codec: VideoCodecChoice = .h264
    @State private var sizeIndex = 0
    @State private var fps: Double = 30
    @State private var quality: Double = 0.8
    @State private var status = ""

    var body: some View {
        let d = AppModel.shared.activeDocument
        DialogFrame(title: "Render Video", width: 420, okTitle: "Render…", onOK: render) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Format", selection: $codec) { ForEach(VideoCodecChoice.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 300)
                Picker("Size", selection: $sizeIndex) {
                    Text("Document Size" + (d.map { " (\($0.state.width)×\($0.state.height))" } ?? "")).tag(0)
                    Text("50%").tag(1); Text("HD 1920×1080").tag(2); Text("HD 1280×720").tag(3)
                }.frame(width: 300)
                HStack {
                    Text("Frame Rate").frame(width: 80, alignment: .leading)
                    TextField("", value: $fps, format: .number).frame(width: 60)
                    Text("fps")
                }
                if codec != .prores && codec != .png && codec != .tiff { ValueSlider(label: "Quality", value: $quality, range: 0.1...1, format: "%.2f") }
                if let d {
                    let st = VideoRenderer.timeline(for: d.state)
                    let dur = st.videoTimeline?.duration ?? 0
                    Text(String(format: "Duration %.2f s · %d frames", dur, Int((dur * VideoRenderer.validFrameRate(fps)).rounded()))).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
                if !status.isEmpty { Text(status).font(Theme.fontSmall).foregroundStyle(Theme.textDim) }
            }
        }
        .onAppear { if let r = d?.state.videoTimeline?.frameRate { fps = r } }
    }

    func settings(_ d: Document) -> VideoRenderSettings {
        var s = VideoRenderSettings(codec: codec, frameRate: fps, quality: quality)
        switch sizeIndex {
        case 1: s.width = max(2, d.state.width / 2); s.height = max(2, d.state.height / 2)
        case 2: s.width = 1920; s.height = 1080
        case 3: s.width = 1280; s.height = 720
        default: break
        }
        return s
    }

    func render() {
        guard let d = AppModel.shared.activeDocument else { return }
        VideoTimelineController.shared.stop()
        TimelineController.shared.stop()
        let s = settings(d)
        let base = (d.name as NSString).deletingPathExtension
        do {
            if codec.isSequence {
                guard let folder = FilesUI.chooseFolder(message: "Choose a folder for the image sequence") else { return }
                let urls = try VideoRenderer.writeSequence(d.committedState, folder: folder, baseName: base, settings: s)
                AppModel.shared.setStatus("Rendered \(urls.count) frames.")
            } else {
                let p = NSSavePanel()
                p.allowedContentTypes = codec == .prores ? [.quickTimeMovie] : [.mpeg4Movie, .quickTimeMovie]
                p.nameFieldStringValue = base + "." + codec.fileExtension
                guard UIBlock.run(p) == .OK, let url = p.url else { return }
                AppModel.shared.setStatus("Rendering video…")
                try VideoRenderer.writeMovie(d.committedState, to: url, settings: s)
                AppModel.shared.setStatus("Rendered \(url.lastPathComponent)")
            }
        } catch {
            AppActions.alert("Render failed.", error.localizedDescription)
        }
    }
}
