import AppKit
import CoreImage
import Observation
import ImageCratCore

// MARK: - Clipboard History
//
// Keeps the last N things copied inside Lumen (layers with full fidelity, pixel selections, text, colours, layer
// styles, shapes / paths) and images / text copied in other apps while Lumen is frontmost. Nothing is recorded for
// pasteboard items flagged as concealed / transient (password managers), and plain text from other apps that looks
// like a secret is not stored. History is kept in memory only unless "Keep history between launches" is switched on
// (pinned items always persist).

enum ClipKind: String, Codable, CaseIterable {
    case layers, pixels, image, text, color, style, path

    var label: String {
        switch self {
        case .layers: return "Layer"
        case .pixels: return "Pixels"
        case .image: return "Image"
        case .text: return "Text"
        case .color: return "Colour"
        case .style: return "Layer Style"
        case .path: return "Shape"
        }
    }

    var symbol: String {
        switch self {
        case .layers: return "square.3.layers.3d"
        case .pixels: return "square.dashed"
        case .image: return "photo"
        case .text: return "textformat"
        case .color: return "paintpalette"
        case .style: return "fx"
        case .path: return "scribble.variable"
        }
    }
}

enum ClipPasteMode: String, CaseIterable {
    case newLayer = "Paste as New Layer"
    case inPlace = "Paste in Place"
    case intoSelection = "Paste Into Selection"
    case style = "Paste Style"
}

struct ClipItem: Codable, Identifiable {
    var id = UUID()
    var kind: ClipKind
    var date = Date()
    var pinned = false
    var fromLumen = true
    /// "ImageCrat" or the name of the app that was frontmost before ImageCrat.
    var sourceName = Brand.name
    var title: String

    // Payloads (by kind)
    var layers: [Layer]? = nil
    /// Main components used by `layers` (so instances paste into any document).
    var masters: [ComponentMaster]? = nil
    var canvasSize: CGSize? = nil
    var buffer: PixelBuffer? = nil
    var origin: IPoint? = nil
    var text: String? = nil
    var color: RGBA? = nil
    var style: LayerEffects? = nil
    var shape: ShapeContent? = nil

    init(kind: ClipKind, title: String) { self.kind = kind; self.title = title }

    private enum K: String, CodingKey { case id, kind, date, pinned, fromLumen, sourceName, title, layers, masters, canvasSize, buffer, origin, text, color, style, shape }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        kind = try c.decode(ClipKind.self, forKey: .kind)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        date = (try? c.decodeIfPresent(Date.self, forKey: .date)) ?? Date()
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        fromLumen = (try? c.decodeIfPresent(Bool.self, forKey: .fromLumen)) ?? true
        sourceName = (try? c.decodeIfPresent(String.self, forKey: .sourceName)) ?? Brand.name
        if sourceName == Brand.Legacy.name && fromLumen { sourceName = Brand.name }   // saved before the rename
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? kind.label
        layers = try? c.decodeIfPresent([Layer].self, forKey: .layers)
        masters = try? c.decodeIfPresent([ComponentMaster].self, forKey: .masters)
        canvasSize = try? c.decodeIfPresent(CGSize.self, forKey: .canvasSize)
        buffer = try? c.decodeIfPresent(PixelBuffer.self, forKey: .buffer)
        origin = try? c.decodeIfPresent(IPoint.self, forKey: .origin)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
        color = try? c.decodeIfPresent(RGBA.self, forKey: .color)
        style = try? c.decodeIfPresent(LayerEffects.self, forKey: .style)
        shape = try? c.decodeIfPresent(ShapeContent.self, forKey: .shape)
    }

    /// Rough memory footprint (history size cap).
    var byteSize: Int {
        var n = (text?.utf8.count ?? 0) + 256
        if let b = buffer { n += b.width * b.height * b.bytesPerPixel }
        for l in layers ?? [] { n += ClipItem.bytes(l) }
        return n
    }

    private static func bytes(_ l: Layer) -> Int {
        var n = 512
        if let r = l.raster { n += r.buffer.width * r.buffer.height * 4 }
        if let m = l.mask { n += m.buffer.width * m.buffer.height }
        for c in l.children { n += bytes(c) }
        return n
    }

    var subtitle: String {
        var parts = [kind.label]
        switch kind {
        case .layers:
            if let ls = layers { parts = [ls.count == 1 ? ls[0].kindName : "\(ls.count) layers"] }
            if layers?.contains(where: { $0.isComponentInstance }) == true { parts = ["Component instance"] }
        case .pixels, .image: if let b = buffer { parts.append("\(b.width)×\(b.height)") }
        case .text: if let t = text { parts.append("\(t.count) characters") }
        case .color: if let c = color { parts.append("#" + c.hex) }
        case .style: if let s = style { parts.append(s.activeNames.prefix(2).joined(separator: ", ")) }
        case .path: if let s = shape { parts = [s.geometry.kindName] }
        }
        if !fromLumen { parts.append("from \(sourceName)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

@Observable
final class ClipboardHistory {
    static let shared = ClipboardHistory()
    static let dragPrefix = "lumen-clip:"
    static let concealedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "Pasteboard generator type",
    ]

    /// Newest first.
    private(set) var items: [ClipItem] = []
    var maxItems: Int { didSet { savePrefs(); trim() } }
    /// Off by default (privacy): only pinned items are written to disk.
    var persistAll: Bool { didSet { savePrefs(); save() } }
    var captureExternal: Bool { didSet { savePrefs() } }
    /// Memory cap for unpinned items.
    static let maxBytes = 384 * 1024 * 1024

    @ObservationIgnored var pasteboard: NSPasteboard = .general
    @ObservationIgnored var lastChangeCount = -1
    @ObservationIgnored private var lastStyle: LayerEffects?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// The item that mirrors the current system clipboard (⌘V pastes it with full fidelity).
    @ObservationIgnored var currentItemID: UUID?
    @ObservationIgnored var currentChangeCount = -1
    @ObservationIgnored private var lastFrontApp = "another app"
    @ObservationIgnored private var thumbs: [UUID: CGImage] = [:]
    /// Self tests keep preferences and files away from the user's defaults.
    @ObservationIgnored var usesUserDefaults = !CommandLine.arguments.contains("--selftest")

    private init() {
        let d = UserDefaults.standard
        let live = !CommandLine.arguments.contains("--selftest")
        maxItems = live ? (d.object(forKey: "Lumen.Clipboard.Max") as? Int ?? 25) : 25
        persistAll = live ? d.bool(forKey: "Lumen.Clipboard.Persist") : false
        captureExternal = live ? (d.object(forKey: "Lumen.Clipboard.External") as? Bool ?? true) : true
    }

    private func savePrefs() {
        guard usesUserDefaults else { return }
        let d = UserDefaults.standard
        d.set(maxItems, forKey: "Lumen.Clipboard.Max")
        d.set(persistAll, forKey: "Lumen.Clipboard.Persist")
        d.set(captureExternal, forKey: "Lumen.Clipboard.External")
    }

    // MARK: Monitoring

    /// Starts watching the pasteboard. It is polled only while Lumen is the frontmost app.
    func start() {
        guard observers.isEmpty else { return }
        load()
        lastChangeCount = pasteboard.changeCount
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.poll(external: true)
            self?.startTimer()
        })
        observers.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.timer?.invalidate(); self?.timer = nil
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
               let name = app.localizedName { self?.lastFrontApp = name }
        })
        if NSApp?.isActive == true { startTimer() }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard NSApp.isActive else { return }
            self?.poll(external: false)
        }
    }

    /// Checks the pasteboard (and the layer-style clipboard) for something new. `external`: the change happened
    /// while another app was frontmost.
    func poll(external: Bool) {
        if let fx = AppActions.copiedEffects, fx != lastStyle {
            lastStyle = fx
            recordStyle(fx, name: AppActions.doc?.activeLayer?.name)
        }
        let cc = pasteboard.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        if cc == currentChangeCount { return }          // our own write
        capturePasteboard(external: external)
    }

    /// Records the current pasteboard contents (image or text) unless they are concealed or look like a secret.
    @discardableResult
    func capturePasteboard(external: Bool) -> ClipItem? {
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        if !types.isDisjoint(with: Self.concealedTypes) { return nil }        // password managers: never recorded
        if external && !captureExternal { return nil }
        let source = external ? lastFrontApp : Brand.name
        // Text first when the pasteboard is primarily text (rich text also offers an image rendering sometimes).
        let str = pasteboard.string(forType: .string)
        let hasImage = types.contains(NSPasteboard.PasteboardType.png.rawValue) || types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
        if hasImage || (str == nil && NSImage.canInit(with: pasteboard)) {
            guard let img = NSImage(pasteboard: pasteboard), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  cg.width * cg.height <= 64_000_000, cg.width > 0 else { return nil }
            var it = ClipItem(kind: .image, title: "Image \(cg.width)×\(cg.height)")
            it.buffer = PixelBuffer(cgImage: cg)
            it.fromLumen = !external
            it.sourceName = source
            return add(it, changeCount: pasteboard.changeCount)
        }
        guard let s = str, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, s.utf16.count <= 100_000 else { return nil }
        if let c = Self.parseColor(s) {
            var it = ClipItem(kind: .color, title: "#" + c.hex)
            it.color = c
            it.text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            it.fromLumen = !external
            it.sourceName = source
            return add(it, changeCount: pasteboard.changeCount)
        }
        if external && Self.looksSecret(s) { return nil }                       // never stored
        var it = ClipItem(kind: .text, title: Self.snippet(s))
        it.text = s
        it.fromLumen = !external
        it.sourceName = source
        return add(it, changeCount: pasteboard.changeCount)
    }

    static func snippet(_ s: String) -> String {
        let one = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return one.count > 60 ? String(one.prefix(60)) + "…" : one
    }

    // MARK: Secret heuristics

    /// True for plain text that is probably a password, token, key or one-time code.
    static func looksSecret(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return false }
        let lower = s.lowercased()
        if s.contains("-----BEGIN") || lower.contains("private key") { return true }
        for marker in ["password=", "passwd=", "pwd=", "api_key=", "apikey=", "secret=", "token=", "authorization: bearer", "aws_secret_access_key"] where lower.contains(marker) { return true }
        // Multi-word prose is not a secret.
        if s.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) { return false }
        let prefixes = ["sk-", "sk_live_", "sk_test_", "pk_live_", "rk_live_", "ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "xoxb-", "xoxp-", "xoxa-", "AKIA", "ASIA", "AIza", "eyJ", "glpat-", "hf_", "r8_", "npm_", "shpat_", "SG."]
        if s.count >= 12, prefixes.contains(where: { s.hasPrefix($0) }) { return true }
        if s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("file://") || s.hasPrefix("/") || s.hasPrefix("~/") {
            // URLs with embedded credentials or token-ish query values are secrets too
            return lower.contains("token=") || lower.contains("key=") || lower.contains("password") || (s.contains("@") && s.contains("://") && s.split(separator: "@").first?.contains(":") == true && s.components(separatedBy: "://").last?.split(separator: "@").first?.contains(":") == true)
        }
        let scalars = Array(s.unicodeScalars)
        let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        if digits == scalars.count { return scalars.count >= 6 && scalars.count <= 8 }      // one-time codes
        if s.contains("@") && s.contains(".") && !s.contains(":") { return false }          // e-mail address
        let uppers = scalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count
        let lowers = scalars.filter { CharacterSet.lowercaseLetters.contains($0) }.count
        let symbols = scalars.count - digits - uppers - lowers
        let classes = [digits, uppers, lowers, symbols].filter { $0 > 0 }.count
        if scalars.count >= 8 && scalars.count <= 256 {
            // file names / identifiers such as "IMG_2041.png" or "my-file.v2" are not secrets
            if s.range(of: "^[A-Za-z0-9_\\-\\.]+\\.[A-Za-z]{2,5}$", options: .regularExpression) != nil, entropy(s) < 4.0 { return false }
            if classes >= 4 { return true }
            if classes == 3 && digits >= 1 && entropy(s) >= 3.0 { return true }
            if scalars.count >= 20 && digits >= 2 && entropy(s) >= 3.4 { return true }     // hex / base64 keys
        }
        return false
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ s: String) -> Double {
        var f: [Character: Double] = [:]
        for ch in s { f[ch, default: 0] += 1 }
        let n = Double(s.count)
        return -f.values.reduce(0) { $0 + ($1 / n) * log2($1 / n) }
    }

    /// "#RRGGBB", "#RGB", "RRGGBB", "rgb(r, g, b)", "rgba(r, g, b, a)".
    static func parseColor(_ raw: String) -> RGBA? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count <= 40 else { return nil }
        if s.hasPrefix("#"), let c = RGBA(hex: s) { return c }
        let lower = s.lowercased().replacingOccurrences(of: " ", with: "")
        if lower.hasPrefix("rgb"), let open = lower.firstIndex(of: "("), lower.hasSuffix(")") {
            let inner = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == "/" }).map { String($0) }
            guard parts.count == 3 || parts.count == 4 else { return nil }
            func comp(_ p: String) -> Double? { p.hasSuffix("%") ? Double(p.dropLast()).map { $0 / 100 } : Double(p).map { $0 / 255 } }
            guard let r = comp(parts[0]), let g = comp(parts[1]), let b = comp(parts[2]) else { return nil }
            var a = 1.0
            if parts.count == 4 { a = parts[3].hasSuffix("%") ? (Double(parts[3].dropLast()) ?? 100) / 100 : (Double(parts[3]) ?? 1) }
            return RGBA(r: clamp(r, 0, 1), g: clamp(g, 0, 1), b: clamp(b, 0, 1), a: clamp(a, 0, 1))
        }
        return nil
    }

    // MARK: Recording (things copied inside Lumen)

    @discardableResult
    private func add(_ item: ClipItem, changeCount: Int? = nil) -> ClipItem {
        // A re-copy of the same thing moves it to the top instead of duplicating it.
        if let i = items.firstIndex(where: { Self.same($0, item) }) {
            var old = items.remove(at: i)
            old.date = Date()
            items.insert(old, at: 0)
            if let cc = changeCount { currentItemID = old.id; currentChangeCount = cc }
            return old
        }
        items.insert(item, at: 0)
        if let cc = changeCount { currentItemID = item.id; currentChangeCount = cc }
        trim()
        if persistAll { save() }
        return item
    }

    private static func same(_ a: ClipItem, _ b: ClipItem) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .text: return a.text == b.text
        case .color: return a.color == b.color
        case .style: return a.style == b.style
        case .path: return a.shape == b.shape
        case .pixels, .image: return a.buffer != nil && a.buffer === b.buffer
        case .layers: return false
        }
    }

    private func trim() {
        var unpinned = items.filter { !$0.pinned }.count
        while unpinned > max(1, maxItems), let i = items.lastIndex(where: { !$0.pinned }) {
            thumbs[items[i].id] = nil
            items.remove(at: i); unpinned -= 1
        }
        var bytes = items.filter { !$0.pinned }.reduce(0) { $0 + $1.byteSize }
        while bytes > Self.maxBytes, items.filter({ !$0.pinned }).count > 1, let i = items.lastIndex(where: { !$0.pinned }) {
            bytes -= items[i].byteSize
            thumbs[items[i].id] = nil
            items.remove(at: i)
        }
    }

    /// Hook in `AppActions.copy`: called right after Lumen wrote pixels to the pasteboard.
    func noteInternalCopy(merged: Bool) {
        guard let c = AppActions.clipboard, let d = AppActions.doc else { return }
        lastChangeCount = c.changeCount
        record(copyOf: d, buffer: c.buffer, origin: c.origin, merged: merged, changeCount: c.changeCount)
    }

    /// Records a copy made in `d`: whole layers (no selection) keep full fidelity; a selection or a merged copy is pixels.
    @discardableResult
    func record(copyOf d: Document, buffer: PixelBuffer, origin: IPoint, merged: Bool, changeCount: Int? = nil) -> ClipItem {
        if !merged, d.state.selection == nil, d.editTarget != .mask, let active = d.activeLayer {
            let sel = Set(d.orderedSelection)
            var ids = d.orderedSelection.filter { id in
                var p = d.state.parentID(of: id)
                while let x = p { if sel.contains(x) { return false }; p = d.state.parentID(of: x) }
                return true
            }
            if !ids.contains(active.id) { ids = [active.id] }
            let layers = ids.compactMap { d.state.layer($0) }
            return recordLayers(layers, from: d.state, preview: buffer, origin: origin, changeCount: changeCount)
        }
        var it = ClipItem(kind: .pixels, title: merged ? "Merged copy" : "Selection from “\(d.activeLayer?.name ?? "layer")”")
        it.buffer = buffer
        it.origin = origin
        it.canvasSize = CGSize(width: d.state.width, height: d.state.height)
        return add(it, changeCount: changeCount)
    }

    @discardableResult
    func recordLayers(_ layers: [Layer], from st: DocumentState, preview: PixelBuffer? = nil, origin: IPoint? = nil, changeCount: Int? = nil) -> ClipItem {
        var it = ClipItem(kind: .layers, title: layers.count == 1 ? layers[0].name : "\(layers.count) layers")
        it.layers = layers
        let used = ComponentEngine.dependencies(of: ComponentEngine.usedComponentIDs(layers), table: st.components)
        let ms = used.compactMap { st.components[$0] }
        if !ms.isEmpty { it.masters = ms; ComponentRegistry.remember(Dictionary(ms.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })) }
        it.canvasSize = CGSize(width: st.width, height: st.height)
        if let p = preview {
            it.buffer = p; it.origin = origin
        } else {
            // render the layers' appearance for the thumbnail / raster fallbacks
            let sp = CanvasSpace(width: st.width, height: st.height)
            var u: CGRect? = nil
            for l in layers { if let b = Compositor.shared.contentBounds(l, state: st) { u = u.map { $0.union(b) } ?? b } }
            let r = IRect(enclosing: (u ?? st.canvasCGRect).insetBy(dx: -8, dy: -8)).intersection(st.canvasRect)
            if !r.isEmpty {
                let img = Compositor.shared.composite(layers: layers.map { var l = $0; l.isClipped = false; return l }, backdrop: CIImage.clearImage.cropped(to: sp.ciCanvas), space: sp, options: Compositor.Options(globalLight: st.globalLight))
                it.buffer = RenderEngine.renderBuffer(img, docRect: r, space: sp)
                it.origin = r.origin
            }
        }
        return add(it, changeCount: changeCount)
    }

    @discardableResult
    func recordStyle(_ fx: LayerEffects, name: String? = nil) -> ClipItem {
        var it = ClipItem(kind: .style, title: name.map { "Style of “\($0)”" } ?? "Layer style")
        it.style = fx
        return add(it)
    }

    @discardableResult
    func recordText(_ s: String, fromLumen: Bool = true) -> ClipItem {
        var it = ClipItem(kind: .text, title: Self.snippet(s))
        it.text = s
        it.fromLumen = fromLumen
        return add(it)
    }

    @discardableResult
    func recordColor(_ c: RGBA) -> ClipItem {
        var it = ClipItem(kind: .color, title: "#" + c.hex)
        it.color = c
        it.text = "#" + c.hex
        return add(it)
    }

    @discardableResult
    func recordShape(_ s: ShapeContent, name: String) -> ClipItem {
        var it = ClipItem(kind: .path, title: name)
        it.shape = s
        return add(it)
    }

    /// Writes text to the system pasteboard and remembers it as ours (the poll will not record it twice).
    func writeToPasteboard(text: String, item: ClipItem? = nil) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        currentChangeCount = pasteboard.changeCount
        currentItemID = item?.id
    }

    /// Edit ▸ Copy Foreground Colour as Hex.
    func copyColor(_ c: RGBA) {
        let it = recordColor(c)
        writeToPasteboard(text: "#" + c.hex, item: it)
    }

    // MARK: Item management

    func item(_ id: UUID) -> ClipItem? { items.first { $0.id == id } }

    func togglePin(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].pinned.toggle()
        trim()
        save()
    }

    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let wasPinned = items[i].pinned
        items.remove(at: i)
        thumbs[id] = nil
        if wasPinned || persistAll { save() }
    }

    /// Clears the history. Pinned items stay unless `includingPinned`.
    func clear(includingPinned: Bool = false) {
        items.removeAll { includingPinned || !$0.pinned }
        thumbs = thumbs.filter { k, _ in items.contains { $0.id == k } }
        save()
    }

    // MARK: Persistence

    var fileURL: URL { ComponentsSupport.directory.appendingPathComponent("clipboard-history.plist") }

    /// Writes the pinned items (all items when "Keep history between launches" is on).
    func save() {
        let keep = items.filter { $0.pinned || persistAll }
        if keep.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        ComponentsSupport.ensure(ComponentsSupport.directory)
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        guard let data = try? enc.encode(keep) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL), let saved = try? PropertyListDecoder().decode([ClipItem].self, from: data) else { return }
        let existing = Set(items.map(\.id))
        items += saved.filter { !existing.contains($0.id) }
        items.sort { $0.date > $1.date }
    }

    /// Test support: forget everything in memory (the file is untouched).
    func resetForTesting() {
        items = []; thumbs = [:]; currentItemID = nil; currentChangeCount = -1; lastStyle = AppActions.copiedEffects
    }

    // MARK: Thumbnails

    func thumbnail(_ item: ClipItem) -> CGImage? {
        if let t = thumbs[item.id] { return t }
        var cg: CGImage?
        switch item.kind {
        case .layers, .pixels, .image:
            if let b = item.buffer { cg = Self.fit(b.makeCGImage(), 112) }
        case .style:
            if let fx = item.style {
                var st = DocumentState(width: 96, height: 96)
                var l = Layer(name: "s", content: .shape(ShapeContent(geometry: .rectangle(CGRect(x: 22, y: 22, width: 52, height: 52), cornerRadius: 12), fill: .color(RGBA(gray: 0.62)))))
                l.effects = LayerTransformer.scaled(fx, 0.6)
                st.layers = [l]
                cg = ComponentEngine.render(st, fit: 112)
            }
        case .path:
            if let s = item.shape {
                let b = ShapeRenderer.docBounds(s).insetBy(dx: -4, dy: -4)
                if b.width > 0, b.height > 0 {
                    let k = min(1, 200 / max(b.width, b.height))
                    var st = DocumentState(width: max(1, Int(b.width * k)), height: max(1, Int(b.height * k)))
                    var sc = s
                    sc.transform = sc.transform.concatenating(CGAffineTransform(translationX: -b.minX, y: -b.minY)).concatenating(CGAffineTransform(scaleX: k, y: k))
                    sc.perspective = nil
                    if sc.fill.isNone && sc.stroke.paint.isNone { sc.stroke = StrokeStyle(paint: .color(.white), width: 2) }
                    st.layers = [Layer(name: "p", content: .shape(sc))]
                    cg = ComponentEngine.render(st, fit: 112)
                }
            }
        case .text, .color: break
        }
        if let cg { thumbs[item.id] = cg }
        return cg
    }

    static func fit(_ cg: CGImage, _ px: CGFloat) -> CGImage? {
        let s = min(1, min(px / CGFloat(cg.width), px / CGFloat(cg.height)))
        let w = max(1, Int(CGFloat(cg.width) * s)), h = max(1, Int(CGFloat(cg.height) * s))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Pasting

    /// Modes that make sense for an item (first = default action).
    static func modes(for item: ClipItem) -> [ClipPasteMode] {
        switch item.kind {
        case .layers: return [.newLayer, .inPlace, .intoSelection, .style]
        case .pixels: return [.newLayer, .inPlace, .intoSelection]
        case .image: return [.newLayer, .intoSelection]
        case .text, .path: return [.newLayer]
        case .color: return [.newLayer]
        case .style: return [.style]
        }
    }

    /// Hook in `AppActions.paste`: when the system clipboard still holds a Lumen layer copy that is more than plain
    /// pixels (text, shape, smart object, component instance, group, styled layer), paste the real layers.
    func handlePaste(inPlace: Bool) -> Bool {
        guard pasteboard.changeCount == currentChangeCount, let id = currentItemID, let it = item(id), it.kind == .layers,
              let layers = it.layers, let d = AppActions.doc else { return false }
        let live = layers.count > 1 || layers.contains { !$0.isRaster || $0.effects.hasAny || $0.mask != nil || $0.vectorMask != nil }
        guard live else { return false }
        return paste(id, mode: inPlace ? .inPlace : .newLayer, into: d, at: nil, keepPositionIfVisible: true)
    }

    /// Pastes a history item. `at` (doc coords) centres the content there (drag to canvas).
    @discardableResult
    func paste(_ id: UUID, mode: ClipPasteMode, into d: Document, at point: CGPoint? = nil, keepPositionIfVisible: Bool = false) -> Bool {
        guard let it = item(id) else { return false }
        AppActions.canvas?.commitCurrentTool()
        switch (it.kind, mode) {
        case (.style, _), (.layers, .style):
            guard let fx = it.style ?? it.layers?.first?.effects else { return false }
            let ids = d.orderedSelection
            guard !ids.isEmpty else { return false }
            for lid in ids { d.updateLayer(lid) { $0.effects = fx } }
            d.commit("Paste Layer Style")
            return true
        case (.color, _):
            guard let c = it.color else { return false }
            AppModel.shared.foreground = c
            AppModel.shared.pushRecent(c)
            if mode == .newLayer && point != nil {
                d.addLayer(Layer(name: d.nextLayerName("Color Fill"), content: .fill(FillContent(paint: .color(c)))), commitName: "New Color Fill Layer")
            } else {
                AppModel.shared.setStatus("Foreground colour set to #\(c.hex).")
            }
            return true
        case (.text, _):
            guard let s = it.text else { return false }
            var t = TextContent()
            t.text = s
            t.fontName = AppModel.shared.textTool.fontName
            t.fontSize = AppModel.shared.textTool.fontSize
            t.color = AppModel.shared.textTool.color ?? AppModel.shared.foreground
            t.alignment = AppModel.shared.textTool.alignment
            let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
            if s.count > 60 || s.contains("\n") {
                // long text becomes a paragraph box so it wraps inside the canvas
                t.fontSize = min(t.fontSize, max(12, Double(H) / 18))
                let bw = min(W * 0.8, 640)
                t.boxSize = CGSize(width: bw, height: min(H * 0.8, max(80, CGFloat(t.fontSize) * 1.3 * CGFloat(max(2, s.count / 28)))))
            }
            let size = TextRenderer.layoutSize(t)
            let c = point ?? viewCenter(d)
            t.position = CGPoint(x: (c.x - size.width / 2).rounded(), y: (c.y - size.height / 2).rounded())
            d.addLayer(Layer(name: String(Self.snippet(s).prefix(24)), content: .text(t)))
            d.commit("Paste Text")
            return true
        case (.path, _):
            guard var s = it.shape else { return false }
            if let p = point {
                let b = s.path.bounds
                let t = CGAffineTransform(translationX: p.x - b.midX, y: p.y - b.midY)
                if s.perspective != nil { s.perspective = Homography(affine: t).concat(s.perspective!) } else { s.transform = s.transform.concatenating(t) }
            }
            d.addLayer(Layer(name: it.title, content: .shape(s)))
            d.commit("Paste Shape")
            return true
        case (.layers, .newLayer), (.layers, .inPlace):
            guard let layers = it.layers, !layers.isEmpty else { return false }
            return pasteLayers(layers, item: it, into: d, at: point, inPlace: mode == .inPlace || keepPositionIfVisible)
        case (.layers, .intoSelection), (.pixels, _), (.image, _):
            guard let buf = it.buffer else { return false }
            return pastePixels(buf, origin: it.origin, name: it.kind == .image ? "Pasted Image" : d.nextLayerName(), mode: mode, into: d, at: point)
        }
    }

    private func viewCenter(_ d: Document) -> CGPoint {
        let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
        if let cv = AppActions.canvas, cv.document === d, cv.bounds.width > 10 {
            let v = cv.viewToDoc(CGPoint(x: cv.bounds.midX, y: cv.bounds.midY))
            return CGPoint(x: clamp(v.x, 0, W), y: clamp(v.y, 0, H))
        }
        return CGPoint(x: W / 2, y: H / 2)
    }

    private func pasteLayers(_ src: [Layer], item: ClipItem, into d: Document, at point: CGPoint?, inPlace: Bool) -> Bool {
        var st = d.state
        // bring the main components along
        var addedMasters = false
        for m in item.masters ?? [] where st.components[m.id] == nil { st.components[m.id] = m; addedMasters = true }
        var layers = src.map { ComponentEngine.reidentified($0) }
        _ = addedMasters
        if ComponentCodec.containsInstance(layers) {
            // instances follow THIS document's main components (they may differ from the copied state)
            ComponentEngine.refresh(&layers, table: st.components, only: nil)
        }
        var u: CGRect? = nil
        for l in layers { if let b = Compositor.shared.contentBounds(l, state: st) { u = u.map { $0.union(b) } ?? b } }
        let canvas = st.canvasCGRect
        var delta = CGPoint.zero
        if let p = point, let b = u {
            delta = CGPoint(x: (p.x - b.midX).rounded(), y: (p.y - b.midY).rounded())
        } else if let b = u, !(inPlace && b.intersects(canvas)) {
            let c = viewCenter(d)
            delta = CGPoint(x: (c.x - b.midX).rounded(), y: (c.y - b.midY).rounded())
        }
        if delta != .zero { for i in layers.indices { layers[i].translate(dx: Double(delta.x), dy: Double(delta.y), document: true) } }
        var anchor = d.activeLayerID
        for l in layers {
            var l = l
            l.isClipped = false
            if let a = anchor, st.layer(a) != nil { st.insertLayer(l, above: a) } else { st.layers.append(l) }
            anchor = l.id
        }
        st.selection = nil
        d.state = st
        d.activeLayerID = layers.last?.id
        d.selectedLayerIDs = Set(layers.map(\.id))
        d.editTarget = .content
        d.commit("Paste")
        return true
    }

    private func pastePixels(_ buf: PixelBuffer, origin: IPoint?, name: String, mode: ClipPasteMode, into d: Document, at point: CGPoint?) -> Bool {
        let W = d.state.width, H = d.state.height
        var o: IPoint
        if let p = point {
            o = IPoint(x: Int(p.x) - buf.width / 2, y: Int(p.y) - buf.height / 2)
        } else if mode == .inPlace, let org = origin {
            o = org
        } else {
            let c = viewCenter(d)
            o = IPoint(x: Int(c.x) - buf.width / 2, y: Int(c.y) - buf.height / 2)
        }
        var layer = Layer.raster(name: name, buffer: buf.copy(), origin: o)
        if mode == .intoSelection {
            guard let sel = d.state.selection, let sb = sel.opaqueBounds() else { return false }
            // Paste Into: the content is centred in the selection and revealed only inside it
            if point == nil { layer.raster?.origin = IPoint(x: sb.x + (sb.width - buf.width) / 2, y: sb.y + (sb.height - buf.height) / 2) }
            var m = LayerMask(buffer: sel.copy(), origin: .zero, outsideValue: 0)
            m.isLinked = false
            layer.mask = m
            d.addLayer(layer)
            d.state.selection = nil
            d.commit("Paste Into")
            return true
        }
        _ = (W, H)
        d.addLayer(layer)
        d.state.selection = nil
        d.commit("Paste")
        return true
    }

    /// Makes a history item the current system clipboard again (so ⌘V / other apps get it).
    func copyAgain(_ id: UUID) {
        guard let it = item(id) else { return }
        pasteboard.clearContents()
        switch it.kind {
        case .text, .color:
            pasteboard.setString(it.text ?? ("#" + (it.color?.hex ?? "000000")), forType: .string)
        case .layers, .pixels, .image:
            if let b = it.buffer, let png = b.pngData() {
                pasteboard.setData(png, forType: .png)
                AppActions.clipboard = ClipboardContent(buffer: b, origin: it.origin ?? .zero, changeCount: pasteboard.changeCount)
            }
        case .style:
            if let fx = it.style { AppActions.copiedEffects = fx; lastStyle = fx }
        case .path:
            if let s = it.shape { pasteboard.setString(LayerSVGExport.svg(for: s, name: it.title), forType: .string) }
        }
        lastChangeCount = pasteboard.changeCount
        currentChangeCount = pasteboard.changeCount
        currentItemID = id
        if let i = items.firstIndex(where: { $0.id == id }), i != 0 {
            var x = items.remove(at: i)
            x.date = Date()
            items.insert(x, at: 0)
        }
    }
}
