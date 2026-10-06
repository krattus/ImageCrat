import AppKit
import Observation
import ImageCratCore

/// Timeline (frame animation) state & commands: frame selection per document, playback and
/// syncing layer edits into the selected frame.
@Observable
final class TimelineController {
    static let shared = TimelineController()

    /// Window > Timeline
    var isPanelVisible = false
    /// Selected frame index per document.
    var selection: [UUID: Int] = [:]
    var isPlaying = false
    /// Frame currently shown during playback.
    var playIndex = 0
    @ObservationIgnored private var playDocID: UUID?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var passes = 0
    /// Set while the controller itself mutates layers (suppresses frame sync).
    @ObservationIgnored private var applying = false

    init() {
        // Every history step records the current layer state into the selected frame.
        let previous = Document.willCommit   // keep hooks installed by feature modules
        Document.willCommit = { [weak self] d in previous?(d); self?.syncSelectedFrame(d) }
    }

    /// Makes sure the commit hook is installed (the singleton is created lazily).
    static func install() { _ = shared }

    // MARK: Selection

    func selectedIndex(_ d: Document) -> Int? {
        guard !d.state.frames.isEmpty else { return nil }
        let i = selection[d.id] ?? 0
        return min(max(0, i), d.state.frames.count - 1)
    }

    /// Shows frame `i` (one history step when the layers change).
    func select(_ d: Document, _ i: Int) {
        guard d.state.frames.indices.contains(i) else { return }
        if isPlaying { stop() }
        selection[d.id] = i
        let f = d.state.frames[i]
        if Animation.matches(f, d.state) { return }
        applying = true
        Animation.apply(f, to: &d.state)
        d.commit("Select Frame")
        applying = false
    }

    /// After undo/redo the layers may correspond to a different frame than the selected one: follow them.
    func resync(_ d: Document) {
        guard !isPlaying, !d.state.frames.isEmpty else { return }
        let i = selectedIndex(d) ?? 0
        if selection[d.id] != i { selection[d.id] = i }
        if Animation.matches(d.state.frames[i], d.state) { return }
        if let j = d.state.frames.firstIndex(where: { Animation.matches($0, d.state) }) { selection[d.id] = j }
    }

    /// Commit hook: store layer visibility/position/opacity edits in the selected frame.
    func syncSelectedFrame(_ d: Document) {
        guard !applying, !isPlaying, let i = selectedIndex(d) else { return }
        let st = d.state
        let captured = Animation.capture(st, base: st.frames[i])
        var frames = st.frames
        // A frame stores each layer's anchor. An edit that is more than a move (transform, flip, warp, painting that
        // grows the pixel buffer, rasterize, convert …) shifts the anchor relative to the content: the other frames
        // keep their offset to this frame — otherwise the layer jumps when another frame is selected.
        let before = d.committedState
        // whole-document commands (Image Size, Canvas Size …) have already carried the stored positions along
        let synced = AppActions.lastSyncedFrames
        AppActions.lastSyncedFrames = nil
        for l1 in (synced == st.frames ? [] : st.allLayers) {
            guard let l0 = before.layer(l1.id), let a0 = Animation.anchor(l0), let a1 = Animation.anchor(l1) else { continue }
            let dx = a1.x - a0.x, dy = a1.y - a0.y
            guard abs(dx) > 1e-9 || abs(dy) > 1e-9, !Animation.isPureMove(l0, l1) else { continue }
            for j in frames.indices where j != i {
                if let p = frames[j].positions[l1.id] { frames[j].positions[l1.id] = CGPoint(x: p.x + dx, y: p.y + dy) }
            }
        }
        frames[i] = captured
        for j in frames.indices where j != i { Animation.fillMissing(&frames[j], from: st) }
        if frames != st.frames { d.state.frames = frames }
    }

    // MARK: Frame commands

    func createAnimation(_ d: Document) {
        guard d.state.frames.isEmpty else { return }
        applying = true
        d.state.frames = [Animation.capture(d.state)]
        selection[d.id] = 0
        d.commit("Create Frame Animation")
        applying = false
    }

    /// New frame duplicating the selected one, inserted after it.
    func newFrame(_ d: Document) {
        if isPlaying { stop() }
        guard let i = selectedIndex(d) else { createAnimation(d); return }
        applying = true
        var f = Animation.capture(d.state, base: d.state.frames[i])
        f.id = UUID()
        d.state.frames.insert(f, at: i + 1)
        selection[d.id] = i + 1
        d.commit("New Frame")
        applying = false
    }

    func deleteFrame(_ d: Document) {
        if isPlaying { stop() }
        guard let i = selectedIndex(d) else { return }
        applying = true
        d.state.frames.remove(at: i)
        if !d.state.frames.isEmpty {
            let j = min(i, d.state.frames.count - 1)
            selection[d.id] = j
            Animation.apply(d.state.frames[j], to: &d.state)
        } else {
            selection[d.id] = nil
        }
        d.commit("Delete Frame")
        applying = false
    }

    func deleteAnimation(_ d: Document) {
        if isPlaying { stop() }
        guard !d.state.frames.isEmpty else { return }
        applying = true
        d.state.frames = []
        selection[d.id] = nil
        d.commit("Delete Animation")
        applying = false
    }

    func setDelay(_ d: Document, index: Int, _ delay: Double) {
        guard d.state.frames.indices.contains(index) else { return }
        applying = true
        d.state.frames[index].delay = max(0, delay)
        d.commit("Frame Delay")
        applying = false
    }

    func setDelayForAll(_ d: Document, _ delay: Double) {
        guard !d.state.frames.isEmpty else { return }
        applying = true
        for i in d.state.frames.indices { d.state.frames[i].delay = max(0, delay) }
        d.commit("Frame Delay")
        applying = false
    }

    func setLoop(_ d: Document, _ loop: AnimationLoop) {
        guard d.state.animationLoop != loop else { return }
        applying = true
        d.state.animationLoop = loop
        d.commit("Loop Options")
        applying = false
    }

    /// Inserts `count` interpolated frames between the selected frame and its next (or previous) neighbour.
    func tween(_ d: Document, count: Int, withNext: Bool = true, position: Bool = true, opacity: Bool = true) {
        if isPlaying { stop() }
        guard let i = selectedIndex(d), count > 0 else { return }
        let j = withNext ? i + 1 : i - 1
        guard d.state.frames.indices.contains(j) else { Beep.play(); return }
        let (lo, hi) = (min(i, j), max(i, j))
        let a = d.state.frames[lo], b = d.state.frames[hi]
        let mid = Animation.tween(from: a, to: b, count: count, position: position, opacity: opacity)
        applying = true
        d.state.frames.insert(contentsOf: mid, at: hi)
        if !withNext { selection[d.id] = i + count }
        d.commit("Tween")
        applying = false
    }

    func makeFramesFromLayers(_ d: Document) {
        if isPlaying { stop() }
        let delay = selectedIndex(d).map { d.state.frames[$0].delay } ?? 0.2
        let frames = Animation.framesFromLayers(d.state, delay: delay)
        guard !frames.isEmpty else { return }
        applying = true
        d.state.frames = frames
        selection[d.id] = 0
        Animation.apply(frames[0], to: &d.state)
        d.commit("Make Frames From Layers")
        applying = false
    }

    func reverseFrames(_ d: Document) {
        guard d.state.frames.count > 1 else { return }
        applying = true
        d.state.frames.reverse()
        if let i = selection[d.id] { selection[d.id] = d.state.frames.count - 1 - i }
        d.commit("Reverse Frames")
        applying = false
    }

    // MARK: Transport

    func first(_ d: Document) { select(d, 0) }
    func last(_ d: Document) { select(d, d.state.frames.count - 1) }
    func previous(_ d: Document) {
        guard let i = selectedIndex(d) else { return }
        select(d, i == 0 ? d.state.frames.count - 1 : i - 1)
    }
    func next(_ d: Document) {
        guard let i = selectedIndex(d) else { return }
        select(d, (i + 1) % d.state.frames.count)
    }

    func togglePlay(_ d: Document) {
        if isPlaying { stop() } else { play(d) }
    }

    /// Plays from the selected frame. Frames are applied without history steps.
    func play(_ d: Document) {
        guard d.state.frames.count > 1, let i = selectedIndex(d) else { return }
        stop()
        playDocID = d.id
        playIndex = i
        passes = 0
        isPlaying = true
        schedule(d)
    }

    private func schedule(_ d: Document) {
        let delay = max(0.03, d.state.frames[playIndex].delay)
        let t = Timer(timeInterval: delay, repeats: false) { [weak self, weak d] _ in
            guard let self, let d else { self?.stop(); return }
            self.tick(d)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick(_ d: Document) {
        guard isPlaying, d.id == playDocID, !d.state.frames.isEmpty,
              AppModel.shared.documents.contains(where: { $0 === d }) else { stop(); return }
        var n = playIndex + 1
        if n >= d.state.frames.count {
            passes += 1
            let limit: Int? = { switch d.state.animationLoop { case .once: return 1; case .three: return 3; case .forever: return nil } }()
            if let l = limit, passes >= l { stop(); return }
            n = 0
        }
        playIndex = n
        var st = d.state
        Animation.apply(st.frames[n], to: &st)
        applying = true
        d.state = st
        applying = false
        schedule(d)
    }

    /// Stops playback, selecting the frame that was showing.
    func stop() {
        timer?.invalidate()
        timer = nil
        guard isPlaying else { return }
        isPlaying = false
        guard let id = playDocID, let d = AppModel.shared.documents.first(where: { $0.id == id }) else { return }
        playDocID = nil
        let shown = playIndex
        d.revertUncommitted()
        select(d, min(shown, max(0, d.state.frames.count - 1)))
    }

    // MARK: Dialogs

    func showTweenDialog(_ d: Document) {
        guard let i = selectedIndex(d), d.state.frames.count > 1 else { Beep.play(); return }
        let a = NSAlert()
        a.messageText = tr("Tween")
        a.informativeText = tr("Insert frames that interpolate layer position and opacity.")
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 110))
        let withPopup = NSPopUpButton(frame: NSRect(x: 100, y: 82, width: 160, height: 24))
        withPopup.addItems(withTitles: ["Next Frame", "Previous Frame"])
        if i == d.state.frames.count - 1 { withPopup.selectItem(at: 1) }
        let l1 = NSTextField(labelWithString: tr("Tween With:")); l1.frame = NSRect(x: 0, y: 86, width: 96, height: 18)
        let countField = NSTextField(string: "5"); countField.frame = NSRect(x: 100, y: 56, width: 60, height: 22)
        let l2 = NSTextField(labelWithString: tr("Frames to Add:")); l2.frame = NSRect(x: 0, y: 58, width: 96, height: 18)
        let pos = NSButton(checkboxWithTitle: tr("Position"), target: nil, action: nil); pos.frame = NSRect(x: 100, y: 28, width: 150, height: 20); pos.state = .on
        let op = NSButton(checkboxWithTitle: tr("Opacity"), target: nil, action: nil); op.frame = NSRect(x: 100, y: 4, width: 150, height: 20); op.state = .on
        for s in [withPopup, l1, countField, l2, pos, op] as [NSView] { v.addSubview(s) }
        a.accessoryView = v
        a.addButton(withTitle: tr("OK"))
        a.addButton(withTitle: tr("Cancel"))
        guard UIBlock.run(a) == .alertFirstButtonReturn else { return }
        let n = max(1, min(500, Int(countField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 5))
        tween(d, count: n, withNext: withPopup.indexOfSelectedItem == 0, position: pos.state == .on, opacity: op.state == .on)
    }

    /// "Other…" delay entry. Returns nil when cancelled.
    static func askDelay(current: Double) -> Double? {
        let a = NSAlert()
        a.messageText = tr("Set Frame Delay")
        let f = NSTextField(string: String(format: "%g", current))
        f.frame = NSRect(x: 0, y: 0, width: 120, height: 22)
        a.accessoryView = f
        a.informativeText = tr("Delay in seconds:")
        a.addButton(withTitle: tr("OK"))
        a.addButton(withTitle: tr("Cancel"))
        guard UIBlock.run(a) == .alertFirstButtonReturn,
              let v = Double(f.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
        return min(max(0, v), 240)
    }
}
