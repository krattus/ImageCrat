import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

enum Variables {
    static let trueWords: Set<String> = ["true", "visible", "yes", "1", "on", "show"]

    static func defaultName(_ l: Layer, kind: VariableKind, existing: [LayerVariable]) -> String {
        let base = l.name.replacingOccurrences(of: " ", with: "_")
        var n = kind == .visibility ? base + "_visible" : base
        var i = 2
        while existing.contains(where: { $0.name == n }) { n = base + "_\(i)"; i += 1 }
        return n
    }

    // MARK: CSV / TSV

    /// Parses delimited text (quotes, doubled quotes, CRLF). Tab-delimited when the first line has tabs.
    static func parseDelimited(_ text: String) -> [[String]] {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let sep: Character = firstLine.contains("\t") ? "\t" : (firstLine.contains(";") && !firstLine.contains(",") ? ";" : ",")
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == sep {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    /// Data sets from a text file: first row = variable names, one data set per following row. A column named
    /// "Data Set", "DataSet" or "Name" (when it is not a variable) names the sets.
    static func dataSets(fromText text: String, variables: [LayerVariable]) -> (sets: [DataSet], unmatched: [String]) {
        let rows = parseDelimited(text)
        guard let header = rows.first else { return ([], []) }
        let names = header.map { $0.trimmingCharacters(in: .whitespaces) }
        let varNames = Set(variables.map(\.name))
        let nameCol = names.firstIndex { ["data set", "dataset", "name", "data set name"].contains($0.lowercased()) && !varNames.contains($0) }
        var sets: [DataSet] = []
        for (ri, r) in rows.dropFirst().enumerated() {
            var ds = DataSet(name: "Data Set \(ri + 1)")
            for (ci, v) in r.enumerated() where ci < names.count {
                if ci == nameCol { if !v.isEmpty { ds.name = v }; continue }
                ds.values[names[ci]] = v
            }
            sets.append(ds)
        }
        let unmatched = names.enumerated().filter { $0.offset != nameCol && !varNames.contains($0.element) }.map(\.element)
        return (sets, unmatched)
    }

    // MARK: Apply

    /// Applies a data set to the layers bound to variables (no history step).
    static func apply(_ ds: DataSet, to st: inout DocumentState) {
        guard let vars = st.variables else { return }
        for v in vars.variables {
            guard let value = ds.values[v.name], st.layer(v.layerID) != nil else { continue }
            switch v.kind {
            case .visibility:
                let on = trueWords.contains(value.trimmingCharacters(in: .whitespaces).lowercased())
                st.updateLayer(v.layerID) { $0.isVisible = on }
            case .text:
                st.updateLayer(v.layerID) { l in
                    guard var t = l.text else { return }
                    t.text = value.replacingOccurrences(of: "\\n", with: "\n")
                    t.runs = []
                    l.text = t
                }
            case .pixel:
                let path = value.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { continue }
                var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                if !path.hasPrefix("/") && !path.hasPrefix("~"), let base = vars.baseFolder { url = base.appendingPathComponent(path) }
                guard let (cg, _) = DocumentIO.loadImage(url: url) else { continue }
                replacePixels(v, image: cg, in: &st)
            }
        }
    }

    static func applied(_ ds: DataSet, to st: DocumentState) -> DocumentState {
        var s = st
        apply(ds, to: &s)
        return s
    }

    /// Places `image` into the variable's bounding box using its fit method.
    static func replacePixels(_ v: LayerVariable, image cg: CGImage, in st: inout DocumentState) {
        guard let l = st.layer(v.layerID) else { return }
        let box = v.box ?? Compositor.shared.contentBounds(l, state: st) ?? st.canvasCGRect
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        var r: CGRect
        switch v.fit {
        case .conform: r = box
        case .asIs: r = CGRect(x: box.midX - iw / 2, y: box.midY - ih / 2, width: iw, height: ih)
        case .fit, .fill:
            let s = v.fit == .fit ? min(box.width / iw, box.height / ih) : max(box.width / iw, box.height / ih)
            r = CGRect(x: box.midX - iw * s / 2, y: box.midY - ih * s / 2, width: iw * s, height: ih * s)
        }
        let buf = PixelBuffer(cgImage: cg)
        st.updateLayer(v.layerID) { l in
            if case .smartObject(var so) = l.content {
                so.source = .image(buf)
                so.quad = Quad(rect: r)
                so.warp = nil
                so.sourceRevision = SourceRevision.next()
                so.sourceName = "Replacement"
                l.content = .smartObject(so)
            } else if l.isRaster {
                // raster: redraw into the box (clipped for Fill)
                let ib = IRect(enclosing: box)
                let nb = PixelBuffer(width: ib.width, height: ib.height)
                nb.context.saveGState()
                nb.context.clip(to: CGRect(x: 0, y: 0, width: ib.width, height: ib.height))
                nb.drawImage(cg, in: r.offsetBy(dx: -CGFloat(ib.x), dy: -CGFloat(ib.y)))
                nb.context.restoreGState()
                nb.markDirty()
                l.raster = RasterContent(buffer: nb, origin: ib.origin)
            }
        }
    }

    // MARK: Export

    enum OutputFormat: String, CaseIterable { case psd = "PSD", png = "PNG", jpeg = "JPEG", pdf = "PDF" }

    /// One file per data set: `<prefix><set name>.<ext>`. Returns written URLs.
    @discardableResult
    static func exportDataSets(_ st: DocumentState, folder: URL, prefix: String, format: OutputFormat, sets: [DataSet]? = nil) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        let list = sets ?? st.variables?.dataSets ?? []
        for (i, ds) in list.enumerated() {
            let s = applied(ds, to: st)
            var name = ds.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if name.isEmpty { name = "\(i + 1)" }
            let ext = ["psd", "png", "jpg", "pdf"][OutputFormat.allCases.firstIndex(of: format)!]
            let url = folder.appendingPathComponent(prefix + name + "." + ext)
            switch format {
            case .psd: try PSDWriter.write(s, to: url)
            case .png: try DocumentIO.export(s, to: url, format: .png, quality: 1, scale: 1)
            case .jpeg: try DocumentIO.export(s, to: url, format: .jpeg, quality: 0.9, scale: 1)
            case .pdf: try PDFExport.write(s, to: url)
            }
            urls.append(url)
        }
        return urls
    }
}

// MARK: - Define dialog

struct VariablesDefineDialog: View {
    let doc: Document
    @State private var vars: [LayerVariable]
    @State private var layerID: UUID?

    init(doc: Document) {
        self.doc = doc
        _vars = State(initialValue: doc.state.variables?.variables ?? [])
        _layerID = State(initialValue: doc.activeLayerID)
    }

    private var layers: [Layer] { doc.state.layers.flattenedForDisplay(includeCollapsed: true).map(\.0).filter { !$0.isAdjustment } }
    private var layer: Layer? { doc.state.layer(layerID) }

    var body: some View {
        DialogFrame(title: "Variables", width: 460, onOK: save) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Layer").frame(width: 70, alignment: .leading)
                    Picker("", selection: $layerID) {
                        ForEach(layers) { l in Text(l.name + (vars.contains { $0.layerID == l.id } ? " *" : "")).tag(Optional(l.id)) }
                    }.labelsHidden()
                }
                if let l = layer {
                    kindRow(.visibility, l)
                    if l.isText { kindRow(.text, l) }
                    if l.isSmartObject || l.isRaster { kindRow(.pixel, l) }
                }
                Rectangle().fill(Theme.divider).frame(height: 1)
                Text("Defined variables").font(Theme.fontBold)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(vars) { v in
                            HStack {
                                Text(tr(v.name)).frame(width: 150, alignment: .leading).lineLimit(1)
                                Text(tr(v.kind.rawValue)).foregroundStyle(Theme.textDim)
                                Spacer()
                                Text(tr(doc.state.layer(v.layerID)?.name ?? "—")).foregroundStyle(Theme.textFaint).lineLimit(1)
                            }
                        }
                        if vars.isEmpty { Text("None").foregroundStyle(Theme.textFaint) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 110)
            }
        }
    }

    @ViewBuilder func kindRow(_ kind: VariableKind, _ l: Layer) -> some View {
        let idx = vars.firstIndex { $0.layerID == l.id && $0.kind == kind }
        VStack(alignment: .leading, spacing: 4) {
            Toggle(tr(kind.rawValue), isOn: Binding(get: { idx != nil }, set: { on in
                if on {
                    var v = LayerVariable(name: Variables.defaultName(l, kind: kind, existing: vars), kind: kind, layerID: l.id)
                    if kind == .pixel { v.box = Compositor.shared.contentBounds(l, state: doc.state) }
                    vars.append(v)
                } else if let i = idx { vars.remove(at: i) }
            })).toggleStyle(.checkbox)
            if let i = idx {
                HStack {
                    Text("Name").frame(width: 60, alignment: .leading).padding(.leading, 18)
                    TextField("", text: Binding(get: { vars[i].name }, set: { vars[i].name = $0.replacingOccurrences(of: " ", with: "_") })).frame(width: 180)
                    if kind == .pixel {
                        Picker("", selection: Binding(get: { vars[i].fit }, set: { vars[i].fit = $0 })) {
                            ForEach(PixelFit.allCases, id: \.self) { Text(tr($0.rawValue)).tag($0) }
                        }.labelsHidden().frame(width: 90)
                    }
                }
            }
        }
    }

    func save() {
        var v = doc.state.variables ?? DocumentVariables()
        v.variables = vars
        doc.state.variables = v
        doc.commit("Define Variables")
    }
}

// MARK: - Data Sets dialog

struct VariablesDataSetsDialog: View {
    let doc: Document
    @State private var model: DocumentVariables
    @State private var index = 0
    @State private var preview = true
    @State private var message = ""

    init(doc: Document) {
        self.doc = doc
        _model = State(initialValue: doc.state.variables ?? DocumentVariables())
    }

    var body: some View {
        DialogFrame(title: "Data Sets", width: 480, okTitle: "Apply", onOK: apply, onCancel: { doc.revertUncommitted() }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Import…") { importText() }.buttonStyle(PanelButtonStyle())
                    Button("New Data Set") {
                        var ds = DataSet(name: "Data Set \(model.dataSets.count + 1)")
                        if let cur = current { ds.values = cur.values }
                        model.dataSets.append(ds); index = model.dataSets.count - 1; refresh()
                    }.buttonStyle(PanelButtonStyle())
                    Button("Delete") {
                        guard model.dataSets.indices.contains(index) else { return }
                        model.dataSets.remove(at: index); index = max(0, min(index, model.dataSets.count - 1)); refresh()
                    }.buttonStyle(PanelButtonStyle()).disabled(model.dataSets.isEmpty)
                    Spacer()
                    Toggle2(label: "Preview", on: $preview)
                }
                HStack {
                    IconButton(symbol: "chevron.left", help: "Previous data set") { index = max(0, index - 1); refresh() }
                    IconButton(symbol: "chevron.right", help: "Next data set") { index = min(model.dataSets.count - 1, index + 1); refresh() }
                    if model.dataSets.indices.contains(index) {
                        TextField("", text: $model.dataSets[index].name).frame(width: 200)
                        Text("\(index + 1) of \(model.dataSets.count)").foregroundStyle(Theme.textFaint)
                    } else {
                        Text("No data sets — import a CSV / TSV file (first row: variable names).").foregroundStyle(Theme.textFaint)
                    }
                }
                if model.dataSets.indices.contains(index) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.variables) { v in
                                HStack {
                                    Text(tr(v.name)).frame(width: 150, alignment: .leading).lineLimit(1)
                                    TextField("", text: Binding(get: { model.dataSets[index].values[v.name] ?? "" },
                                                                set: { model.dataSets[index].values[v.name] = $0; refresh() }))
                                    Text(tr(v.kind == .visibility ? "true/false" : (v.kind == .pixel ? "file" : "text"))).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                                }
                            }
                        }
                    }.frame(height: 150)
                }
                if !message.isEmpty { Text(tr(message)).font(Theme.fontSmall).foregroundStyle(Theme.textDim) }
            }
        }
        .onChange(of: preview) { _, _ in refresh() }
        .onAppear { refresh() }
    }

    private var current: DataSet? { model.dataSets.indices.contains(index) ? model.dataSets[index] : nil }

    func refresh() {
        doc.revertUncommitted()
        guard preview, let ds = current else { return }
        var st = doc.state
        st.variables = model
        Variables.apply(ds, to: &st)
        doc.state = st
    }

    func importText() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText, .text]
        guard UIBlock.run(p) == .OK, let url = p.url,
              let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else { return }
        let (sets, unmatched) = Variables.dataSets(fromText: text, variables: model.variables)
        model.dataSets += sets
        model.baseFolder = url.deletingLastPathComponent()
        message = "Imported \(sets.count) data set(s)" + (unmatched.isEmpty ? "." : ". Columns without a variable: " + unmatched.joined(separator: ", "))
        index = max(0, model.dataSets.count - sets.count)
        refresh()
    }

    func apply() {
        doc.revertUncommitted()
        var st = doc.state
        st.variables = model
        if let ds = current { Variables.apply(ds, to: &st) }
        doc.state = st
        doc.commit("Apply Data Set")
    }
}

// MARK: - Export Data Sets as Files

struct ExportDataSetsDialog: View {
    let doc: Document
    @State private var prefix: String
    @State private var format: Variables.OutputFormat = .png
    @State private var folder: URL?

    init(doc: Document) {
        self.doc = doc
        _prefix = State(initialValue: (doc.name as NSString).deletingPathExtension + "_")
    }

    var body: some View {
        DialogFrame(title: "Export Data Sets as Files", width: 420, okTitle: "Export", onOK: run) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(doc.state.variables?.dataSets.count ?? 0) data set(s), \(doc.state.variables?.variables.count ?? 0) variable(s)")
                    .foregroundStyle(Theme.textDim)
                HStack {
                    Text("Folder").frame(width: 70, alignment: .leading)
                    Text(folder?.path ?? "—").lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.textDim)
                    Spacer()
                    Button("Choose…") { folder = FilesUI.chooseFolder() }.buttonStyle(PanelButtonStyle())
                }
                HStack {
                    Text("File Name").frame(width: 70, alignment: .leading)
                    TextField("", text: $prefix).frame(width: 160)
                    Text("+ data set name").foregroundStyle(Theme.textFaint)
                }
                Picker("Format", selection: $format) { ForEach(Variables.OutputFormat.allCases, id: \.self) { Text(tr($0.rawValue)).tag($0) } }.frame(width: 200)
            }
        }
    }

    func run() {
        guard let f = folder ?? FilesUI.chooseFolder() else { return }
        do {
            let urls = try Variables.exportDataSets(doc.committedState, folder: f, prefix: prefix, format: format)
            AppModel.shared.setStatus("Exported \(urls.count) data set file(s).")
        } catch { AppActions.alert("Export failed.", error.localizedDescription) }
    }
}
