import AppKit
import SwiftUI
import WebKit
import Observation
import ImageCratCore

// MARK: - Scripting console

@Observable
final class ScriptConsole {
    static let shared = ScriptConsole()
    var lines: [String] = ["ImageCrat JavaScript console — try: app.activeDocument.layers.map(l => l.name)"]
    var history: [String] = []
    @ObservationIgnored lazy var engine: ScriptEngine = {
        let e = ScriptEngine(name: "Console", interactive: true)
        e.log = { [weak self] in self?.append($0) }
        return e
    }()

    func append(_ s: String) {
        lines.append(s)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    func run(_ src: String) {
        let t = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        history.append(t)
        append("› " + t)
        engine.evaluate(t)
    }
}

struct ScriptConsolePanel: View {
    @Bindable var console = ScriptConsole.shared
    @State private var input = ""
    @State private var historyIndex: Int?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(console.lines.enumerated()), id: \.offset) { i, l in
                            Text(tr(l)).font(Theme.mono).foregroundStyle(l.hasPrefix("⚠︎") ? Color.orange : (l.hasPrefix("›") ? Theme.textDim : Theme.text))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(i)
                        }
                    }.padding(6)
                }
                .onChange(of: console.lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 4) {
                TextField("JavaScript…", text: $input)
                    .textFieldStyle(.plain).font(Theme.mono)
                    .onSubmit { console.run(input); input = ""; historyIndex = nil }
                    .onKeyPress(.upArrow) { recall(-1); return .handled }
                    .onKeyPress(.downArrow) { recall(1); return .handled }
                IconButton(symbol: "play.fill", help: "Run") { console.run(input); input = "" }
                Menu {
                    Button("Run Script File…") { ScriptRunner.browse() }
                    Button("Clear") { console.lines = [] }
                    Button("Reset Context") { console.engine = { let e = ScriptEngine(name: "Console"); e.log = { ScriptConsole.shared.append($0) }; return e }() }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 6).frame(height: 28)
            .background(Theme.fieldBG)
        }
    }

    func recall(_ d: Int) {
        guard !console.history.isEmpty else { return }
        let i = max(0, min(console.history.count - 1, (historyIndex ?? console.history.count) + d))
        historyIndex = i
        input = console.history[i]
    }
}

// MARK: - Plugins

struct PluginManifest: Codable {
    var name: String
    var version: String?
    var description: String?
    /// Entry script (evaluated once in the plugin's own context; `run()` is called by Plugins > Run).
    var entry: String?
    /// Optional panel HTML shown in a WKWebView panel with `window.imagecrat.call(method, …args)` (`window.lumen` is an alias).
    var panel: String?
    var panelTitle: String?
    var panelWidth: Double?
    var panelHeight: Double?

    enum CodingKeys: String, CodingKey { case name, version, description, entry, main, panel, panelTitle, panelWidth, panelHeight }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        entry = try c.decodeIfPresent(String.self, forKey: .entry) ?? c.decodeIfPresent(String.self, forKey: .main)
        panel = try c.decodeIfPresent(String.self, forKey: .panel)
        panelTitle = try c.decodeIfPresent(String.self, forKey: .panelTitle)
        panelWidth = try c.decodeIfPresent(Double.self, forKey: .panelWidth)
        panelHeight = try c.decodeIfPresent(Double.self, forKey: .panelHeight)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encodeIfPresent(version, forKey: .version); try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(entry, forKey: .entry); try c.encodeIfPresent(panel, forKey: .panel); try c.encodeIfPresent(panelTitle, forKey: .panelTitle)
    }
}

final class Plugin {
    let folder: URL
    let manifest: PluginManifest
    var panelID: String { "plugin." + folder.lastPathComponent }
    private var _engine: ScriptEngine?

    init(folder: URL, manifest: PluginManifest) { self.folder = folder; self.manifest = manifest }

    /// The plugin's own JS context (entry evaluated on first use).
    var engine: ScriptEngine {
        if let e = _engine { return e }
        let e = ScriptEngine(name: manifest.name, interactive: true)
        e.log = { ScriptConsole.shared.append("[\(self.manifest.name)] " + $0) }
        e.context.setObject(folder.path, forKeyedSubscript: "__pluginFolder" as NSString)
        if let entry = manifest.entry, let src = try? String(contentsOf: folder.appendingPathComponent(entry), encoding: .utf8) {
            e.evaluate(src, file: folder.appendingPathComponent(entry).path)
        }
        _engine = e
        return e
    }
}

final class PluginManager {
    static let shared = PluginManager()
    private(set) var plugins: [Plugin] = []

    init() { reload() }

    func reload(from root: URL = ScriptLibrary.pluginsFolder) {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        plugins = dirs.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { dir in
            guard let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let m = try? JSONDecoder().decode(PluginManifest.self, from: d) else { return nil }
            return Plugin(folder: dir, manifest: m)
        }
    }

    func run(_ p: Plugin) {
        let e = p.engine
        if e.callFunction("run") == nil, let err = e.lastError { AppActions.alert("Plugin “\(p.manifest.name)” failed.", err) }
    }
}

/// WKWebView panel for a plugin. `window.imagecrat.call(method, ...args)` returns a Promise with the API result;
/// `window.imagecrat.invoke(fn, ...args)` calls a function defined in the plugin's entry script. `window.lumen` (and the
/// `lumen` message handler) stay as aliases, so panels written before the rename keep working.
struct PluginPanelView: NSViewRepresentable {
    let plugin: Plugin

    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply {
        let plugin: Plugin
        init(plugin: Plugin) { self.plugin = plugin }
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
            guard let body = message.body as? [String: Any], let method = body["method"] as? String else { replyHandler(nil, "bad message"); return }
            let args = (body["args"] as? [Any]) ?? []
            do {
                let r = try ScriptAPI.dispatch(method, args, engine: plugin.engine)
                replyHandler(PluginPanelView.jsonSafe(r), nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        }
    }

    static func jsonSafe(_ v: Any?) -> Any {
        guard let v else { return NSNull() }
        if let d = v as? [String: Any] { return d.mapValues { jsonSafe($0) } }
        if let a = v as? [Any] { return a.map { jsonSafe($0) } }
        if v is String || v is NSNumber || v is Bool || v is Int || v is Double { return v }
        return "\(v)"
    }

    func makeCoordinator() -> Coordinator { Coordinator(plugin: plugin) }

    func makeNSView(context: Context) -> WKWebView {
        let ucc = WKUserContentController()
        for name in PluginPanelView.bridgeNames { ucc.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: name) }
        ucc.addUserScript(WKUserScript(source: PluginPanelView.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let cfg = WKWebViewConfiguration()
        cfg.userContentController = ucc
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        if let p = plugin.manifest.panel {
            let url = plugin.folder.appendingPathComponent(p)
            wv.loadFileURL(url, allowingReadAccessTo: plugin.folder)
        }
        return wv
    }

    /// Message handlers the panel can post to: `imagecrat`, and `lumen` from before the rename.
    static let bridgeNames = ["imagecrat", "lumen"]
    /// The panel's API object: `window.imagecrat`, with `window.lumen` as an alias for older plugins.
    static let bridge = """
        window.imagecrat = {
          call: (method, ...args) => window.webkit.messageHandlers.imagecrat.postMessage({ method: method, args: args }),
          invoke: (fn, ...args) => window.webkit.messageHandlers.imagecrat.postMessage({ method: 'plugin.invoke', args: [fn, args] }),
          log: (...args) => window.webkit.messageHandlers.imagecrat.postMessage({ method: 'plugin.log', args: args.map(String) })
        };
        window.lumen = window.imagecrat;
        """

    func updateNSView(_ v: WKWebView, context: Context) {}
}

enum ScriptingPanels {
    static func register() {
        PanelRegistry.register(PanelRegistry.Def(id: "scriptConsole", title: "Scripting Console") { AnyView(ScriptConsolePanel()) })
        for p in PluginManager.shared.plugins where p.manifest.panel != nil {
            PanelRegistry.register(PanelRegistry.Def(id: p.panelID, title: p.manifest.panelTitle ?? p.manifest.name) {
                AnyView(PluginPanelView(plugin: p).frame(minHeight: 200))
            })
        }
    }
}

// MARK: - Samples installed on first run

enum SampleScripts {
    static let scripts: [(String, String)] = [
        ("Contact Sheet.js", #"""
        // Contact Sheet — places every image of a folder as a thumbnail grid with captions.
        // Uses: app.chooseFolder, app.listFiles, app.newDocument, doc.placeFile, doc.addTextLayer.
        var folder = typeof arguments !== 'undefined' && arguments.length ? arguments[0] : app.chooseFolder('Choose a folder of images');
        if (folder) {
          var files = app.listFiles(folder);
          if (files.length === 0) { alert('No images in ' + folder); }
          else {
            var answer = prompt('Columns', '4');
            if (answer != null) {   // Cancel in the prompt stops the script
              var cols = Math.max(1, parseInt(answer, 10) || 4);
              var cell = 240, pad = 20, caption = 28;
              var rows = Math.ceil(files.length / cols);
              var doc = app.newDocument(cols * (cell + pad) + pad, rows * (cell + pad + caption) + pad, 'Contact Sheet');
              files.forEach(function (f, i) {
                var c = i % cols, r = Math.floor(i / cols);
                var x = pad + c * (cell + pad), y = pad + r * (cell + pad + caption);
                doc.placeFile(f, { x: x, y: y, width: cell, height: cell });
                var name = f.split('/').pop();
                doc.addTextLayer(name, { x: x, y: y + cell + 4, size: 14, color: '#333333', name: 'Caption ' + (i + 1) });
              });
              console.log('Contact sheet with ' + files.length + ' images');
            }
          }
        }
        """#),
        ("Random Rotate Layers.js", #"""
        // Random Rotate Layers — rotates every visible layer (except the Background) by a random angle.
        var doc = app.activeDocument;
        if (!doc) { alert('Open a document first.'); }
        else {
          var answer = prompt('Maximum angle (degrees)', '25');
          if (answer != null) {   // Cancel in the prompt leaves the document alone
            var max = parseFloat(answer) || 25;
            var n = 0;
            doc.layers.forEach(function (l) {
              if (l.name === 'Background' || !l.visible || l.kind === 'adjustment') return;
              l.rotate((Math.random() * 2 - 1) * max);
              n++;
            });
            app.status('Rotated ' + n + ' layers');
          }
        }
        """#),
    ]

    static let plugins: [(String, [(String, String)])] = [
        ("QuickSwatches", [
            ("manifest.json", #"""
            {
              "name": "Quick Swatches",
              "version": "1.0",
              "description": "One-click colour swatches: set the foreground colour, fill the selection or add a colour layer.",
              "entry": "main.js",
              "panel": "panel.html",
              "panelTitle": "Quick Swatches"
            }
            """#),
            ("main.js", #"""
            // Runs in the plugin's own JavaScript context.
            var palette = ['#E94F37', '#F6AE2D', '#F2E86D', '#3BB273', '#2E86AB', '#7768AE', '#1B1F3A', '#FFFFFF'];
            function swatches() { return palette.concat(app.swatches.slice(6, 18)); }
            function addColorLayer(hex) {
              var doc = app.activeDocument;
              if (!doc) return 'no document';
              var l = doc.addLayer('Swatch ' + hex, { fill: hex });
              l.blendMode = 'color';
              l.opacity = 40;
              return l.name;
            }
            function run() {
              var doc = app.activeDocument;
              if (!doc) { alert('Open a document first.'); return; }
              var w = doc.width, n = palette.length, s = Math.floor(w / n);
              var g = doc.addGroup('Quick Swatches');
              palette.forEach(function (c, i) { doc.addShape('rectangle', { x: i * s, y: 0, width: s, height: Math.max(20, Math.floor(doc.height / 12)), fill: c, name: c }); });
              app.status('Added ' + n + ' swatch shapes');
            }
            """#),
            ("panel.html", #"""
            <!doctype html>
            <html><head><meta charset="utf-8">
            <style>
              body { font: 11px -apple-system, sans-serif; color: #ddd; margin: 8px; background: transparent; }
              .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(26px, 1fr)); gap: 4px; }
              .sw { height: 26px; border-radius: 4px; border: 1px solid #555; cursor: pointer; }
              .sw:hover { outline: 2px solid #4a90e2; }
              button { font: 11px -apple-system; margin: 8px 4px 0 0; }
              #status { margin-top: 6px; color: #999; min-height: 14px; }
            </style></head>
            <body>
              <div class="grid" id="grid"></div>
              <div>
                <button id="fill">Fill Selection</button>
                <button id="layer">Color Layer</button>
              </div>
              <div id="status">Click a swatch to set the foreground colour.</div>
              <script>
                let current = null;
                const status = (t) => document.getElementById('status').textContent = t;
                async function build() {
                  const list = await window.imagecrat.invoke('swatches');
                  const grid = document.getElementById('grid');
                  grid.innerHTML = '';
                  (list || []).forEach(hex => {
                    const d = document.createElement('div');
                    d.className = 'sw'; d.style.background = hex; d.title = hex;
                    d.onclick = async () => { current = hex; await window.imagecrat.call('app.setForegroundColor', hex); status('Foreground: ' + hex); };
                    grid.appendChild(d);
                  });
                }
                document.getElementById('fill').onclick = async () => {
                  try { await window.imagecrat.call('doc.fill', 'active', current || await window.imagecrat.call('app.foregroundColor')); status('Filled'); }
                  catch (e) { status(String(e)); }
                };
                document.getElementById('layer').onclick = async () => {
                  try { const n = await window.imagecrat.invoke('addColorLayer', current || '#E94F37'); status('Added ' + n); }
                  catch (e) { status(String(e)); }
                };
                build();
              </script>
            </body></html>
            """#),
        ]),
    ]
}
