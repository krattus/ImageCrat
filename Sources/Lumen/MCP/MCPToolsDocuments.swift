import AppKit
@testable import LumenUltra
import ImageCratCore

// MCP tools: documents (list / new / open / save / export / close / activate) and inspection (document info, preview,
// selection, history).

private typealias S = MCPSchema

extension MCPTools {
    static let docID = S.string("Id of an open document (from list_documents). Default: the active document.")

    static let saveFormats = ["imagecrat", "psd", "png", "jpeg", "tiff", "webp"]
    static let exportFormats = ["png", "jpeg", "tiff", "webp", "heic", "gif", "bmp", "psd"]

    static func formatFor(_ s: String) -> String? {
        switch s.lowercased() {
        case "imagecrat", Brand.Legacy.documentExtension: return "imagecrat"
        case "psd", "psb": return "psd"
        case "png": return "png"
        case "jpg", "jpeg": return "jpeg"
        case "tif", "tiff": return "tiff"
        case "webp": return "webp"
        case "heic": return "heic"
        case "gif": return "gif"
        case "bmp": return "bmp"
        default: return nil
        }
    }

    static func ext(_ format: String) -> String {
        switch format {
        case "imagecrat": return Brand.documentExtension
        case "jpeg": return "jpg"
        case "tiff": return "tif"
        default: return format
        }
    }

    /// `url` with the format's extension when it has none; an error when the two disagree.
    static func resolve(_ url: URL, format: String?, allowed: [String]) throws -> (URL, String) {
        let fromExt = formatFor(url.pathExtension)
        guard let f = format.map({ $0.lowercased() }) ?? fromExt else {
            throw MCPToolError("Can't tell the file format of “\(url.lastPathComponent)”. Add an extension or pass `format` (\(allowed.joined(separator: ", "))).")
        }
        let fmt = formatFor(f) ?? f
        guard allowed.contains(fmt) else { throw MCPToolError("Unsupported format “\(f)”. Use one of: \(allowed.joined(separator: ", ")).") }
        if url.pathExtension.isEmpty { return (url.appendingPathExtension(ext(fmt)), fmt) }
        if let e = fromExt, e != fmt {
            throw MCPToolError("The path ends in .\(url.pathExtension) but the format is \(fmt). Use a matching extension (.\(ext(fmt))).")
        }
        return (url, fmt)
    }

    static func checkFolder(_ url: URL) throws {
        var dir: ObjCBool = false
        let parent = url.deletingLastPathComponent().path
        guard FileManager.default.fileExists(atPath: parent, isDirectory: &dir), dir.boolValue else {
            throw MCPToolError("The folder \(parent) does not exist.")
        }
    }

    /// Writes the flattened image as WebP (ImageIO when it can encode WebP, else Homebrew's `cwebp`).
    static func writeWebP(_ st: DocumentState, to url: URL, quality: Double, scale: Double) throws {
        guard WXEncoders.available(.webp) else {
            throw MCPToolError("WebP needs the `cwebp` encoder (macOS can't write WebP): install it with `brew install webp`, or use png / jpeg.")
        }
        guard var cg = Compositor.shared.flatten(st) else { throw MCPToolError("The image could not be rendered.") }
        if abs(scale - 1) > 0.001 {
            cg = VideoRenderer.scaled(cg, max(1, Int(Double(cg.width) * scale)), max(1, Int(Double(cg.height) * scale))) ?? cg
        }
        let img = UPBridge.image(cg, forceSRGB: true)
        let data = WXEncoders.cwebpPath != nil ? WXEncoders.cwebp(img, q: quality) : WXEncoders.imageIO(img, type: WXEncoders.webpType, q: quality)
        guard let data else { throw MCPToolError("WebP encoding failed.") }
        try data.write(to: url, options: .atomic)
    }

    /// Saves `d` to `url` in `format`. Layered formats (.imagecrat, PSD) become the document's file.
    static func write(_ d: Document, to url: URL, format: String, quality: Double = 0.9, scale: Double = 1) throws -> String {
        try checkFolder(url)
        let note: String
        switch format {
        case "imagecrat":
            try DocumentIO.saveNative(d, to: url)
            d.fileURL = url; d.name = url.lastPathComponent; d.markSaved()
            note = "layers kept"
        case "psd":
            try PSDWriter.write(d.state, to: url, large: url.pathExtension.lowercased() == "psb")
            d.fileURL = url; d.name = url.lastPathComponent; d.markSaved()
            note = "Photoshop document, layers kept"
        case "webp":
            try writeWebP(d.state, to: url, quality: quality, scale: scale)
            note = "flattened copy"
        default:
            let fmt: ExportFormat
            switch format {
            case "png": fmt = .png
            case "jpeg": fmt = .jpeg
            case "tiff": fmt = .tiff
            case "heic": fmt = .heic
            case "gif": fmt = .gif
            case "bmp": fmt = .bmp
            default: throw MCPToolError("Unsupported format \(format).")
            }
            try DocumentIO.export(d.state, to: url, format: fmt, quality: quality, scale: scale)
            note = "flattened copy"
        }
        MCPServerController.shared.noteWrote(url)
        return note
    }

    // MARK: - Documents

    static let documentTools: [MCPTool] = [
        MCPTool("list_documents", "List Documents",
                "List the open documents (id, name, size, file path, unsaved changes, which one is active).",
                schema: S.object([:]), readOnly: true) { _ in
            let docs = app.documents.map { docJSON($0) }
            return ok(docs.isEmpty ? "No documents are open." : "\(docs.count) open document\(docs.count == 1 ? "" : "s").", ["documents": docs])
        },

        MCPTool("new_document", "New Document",
                "Create a new document and make it active. The background is one pixel layer filled with `background` (or transparent).",
                schema: S.object(["width": S.integer("Width in pixels.", min: 1, max: maxCanvasDimension),
                                  "height": S.integer("Height in pixels.", min: 1, max: maxCanvasDimension),
                                  "background": S.color("Background colour, or \"transparent\". Default white."),
                                  "resolution": S.number("Resolution in pixels per inch.", min: 1, max: 9999, default: 72),
                                  "name": S.string("Document name. Default “Untitled”.")], required: ["width", "height"])) { a in
            let bg: RGBA?
            if let s = a.string("background"), s.lowercased() == "transparent" || s.lowercased() == "none" { bg = nil } else { bg = try a.color("background") ?? .white }
            let d = Document.newBlank(width: a.int("width")!, height: a.int("height")!, resolution: validResolution(a.double("resolution") ?? 72),
                                      background: bg, name: a.string("name") ?? "Untitled")
            app.add(d)
            return ok("Created “\(d.name)” (\(d.state.width) × \(d.state.height) px).", docJSON(d, layers: true))
        },

        MCPTool("open_document", "Open Document",
                "Open an image or document file (absolute path): .imagecrat, .psd/.psb, PNG, JPEG, TIFF, HEIC, WebP, camera RAW, PDF, SVG … It becomes the active document.",
                schema: S.object(["path": S.string("Absolute path of the file to open.", minLength: 1)], required: ["path"])) { a in
            let url = try path(a)
            guard FileManager.default.fileExists(atPath: url.path) else { throw MCPToolError("No file at \(url.path).") }
            if let open = app.documents.first(where: { $0.fileURL?.standardizedFileURL == url }) {
                app.activeDocumentID = open.id
                return ok("“\(open.name)” is already open; it is now the active document.", docJSON(open, layers: true))
            }
            let d: Document
            do { d = try DocumentIO.load(url: url) } catch {
                throw MCPToolError("Could not open \(url.lastPathComponent): \(error.localizedDescription)")
            }
            app.add(d)
            return ok("Opened “\(d.name)” (\(d.state.width) × \(d.state.height) px, \(d.state.allLayers.count) layers).", docJSON(d, layers: true))
        },

        MCPTool("save_document", "Save Document",
                "Save the document. Without `path` it saves to the document's own file. Formats: imagecrat (native, keeps everything), psd (layers), "
                + "png / jpeg / tiff / webp (a flattened copy: the document keeps its own file). The format comes from `format` or the path's extension.",
                schema: S.object(["path": S.string("Absolute path to save to. Default: the document's file."),
                                  "format": S.string("File format.", oneOf: saveFormats),
                                  "quality": S.number("JPEG / WebP quality, 1–100.", min: 1, max: 100, default: 90),
                                  "doc_id": docID])) { a in
            let d = try doc(a)
            let target: URL
            if a.has("path") { target = try path(a) } else {
                guard let u = d.fileURL else {
                    throw MCPToolError("“\(d.name)” has never been saved. Pass an absolute `path`, e.g. /Users/me/Desktop/\((d.name as NSString).deletingPathExtension).\(Brand.documentExtension).")
                }
                target = u
            }
            let (url, fmt) = try resolve(target, format: a.string("format"), allowed: saveFormats)
            let note = try write(d, to: url, format: fmt, quality: (a.double("quality") ?? 90) / 100)
            return ok("Saved “\(d.name)” as \(fmt) to \(url.path) (\(note)).", ["path": url.path, "format": fmt, "document": docJSON(d)])
        },

        MCPTool("export_image", "Export Image",
                "Export a flattened copy of the document (the document itself is not changed). Optionally scaled to fit `size`.",
                schema: S.object(["path": S.string("Absolute path of the file to write.", minLength: 1),
                                  "format": S.string("Image format (default: from the path's extension).", oneOf: exportFormats),
                                  "quality": S.number("JPEG / HEIC / WebP quality, 1–100.", min: 1, max: 100, default: 90),
                                  "size": S.object(["width": S.integer("Maximum width in pixels.", min: 1, max: maxCanvasDimension),
                                                    "height": S.integer("Maximum height in pixels.", min: 1, max: maxCanvasDimension)],
                                                   description: "Fit the image inside this box (aspect ratio kept). Default: full size."),
                                  "doc_id": docID], required: ["path"])) { a in
            let d = try doc(a)
            let (url, fmt) = try resolve(try path(a), format: a.string("format"), allowed: exportFormats)
            var scale = 1.0
            if let s = a.object("size") {
                let w = MCPJSON.double(s["width"]).map { $0 / Double(d.state.width) } ?? .infinity
                let h = MCPJSON.double(s["height"]).map { $0 / Double(d.state.height) } ?? .infinity
                let k = min(w, h)
                if k.isFinite { scale = k }
            }
            if fmt == "psd" && abs(scale - 1) > 0.001 { throw MCPToolError("PSD export can't be resized: drop `size` or use resize_image first.") }
            _ = try write(Document(state: d.state, name: d.name), to: url, format: fmt, quality: (a.double("quality") ?? 90) / 100, scale: scale)
            let w = max(1, Int(Double(d.state.width) * scale)), h = max(1, Int(Double(d.state.height) * scale))
            return ok("Exported \(w) × \(h) \(fmt) to \(url.path).", ["path": url.path, "format": fmt, "width": w, "height": h])
        },

        MCPTool("close_document", "Close Document",
                "Close a document. With unsaved changes pass `save: true` (saves to its file first) or `discard_changes: true`.",
                schema: S.object(["save": S.boolean("Save to the document's file before closing.", default: false),
                                  "discard_changes": S.boolean("Close even though there are unsaved changes (they are lost).", default: false),
                                  "doc_id": docID]), destructive: true) { a in
            let d = try doc(a, activate: false)
            if a.bool("save") == true {
                guard let u = d.fileURL else { throw MCPToolError("“\(d.name)” has never been saved: call save_document with a path first.") }
                let (url, fmt) = try resolve(u, format: nil, allowed: saveFormats)
                _ = try write(d, to: url, format: fmt)
            } else if d.isDirty && a.bool("discard_changes") != true {
                throw MCPToolError("“\(d.name)” has unsaved changes. Pass save: true to save them first, or discard_changes: true to close anyway.")
            }
            let name = d.name
            app.close(d)
            return ok("Closed “\(name)”.", ["closed": name, "active_document_id": (app.activeDocumentID?.uuidString as Any?) ?? NSNull()])
        },

        MCPTool("set_active_document", "Set Active Document",
                "Make a document the active one (shown in the window, used when `doc_id` is omitted).",
                schema: S.object(["doc_id": S.string("Id of the document (from list_documents).", minLength: 1)], required: ["doc_id"])) { a in
            let d = try doc(a)
            return ok("“\(d.name)” is now the active document.", docJSON(d))
        },
    ]

    // MARK: - Inspect

    static let inspectTools: [MCPTool] = [
        MCPTool("get_document_info", "Get Document Info",
                "Size, colour mode, bit depth, resolution, selection and the layer tree (top layer first): ids, names, kinds, visibility, "
                + "opacity, blend mode, bounds, layer effects, text content, children of groups.",
                schema: S.object(["doc_id": docID]), readOnly: true) { a in
            let d = try doc(a, activate: false)
            return ok("“\(d.name)”: \(d.state.width) × \(d.state.height) px, \(d.state.allLayers.count) layers.", docJSON(d, layers: true))
        },

        MCPTool("render_preview", "Render Preview",
                "Render the document (or one layer) as a PNG image, scaled to fit `max_size`. Use it to look at the result of your edits.",
                schema: S.object(["max_size": S.integer("Longest side of the preview in pixels.", min: 16, max: 4096, default: 1024),
                                  "layer_id": S.string("Render only this layer (as if it were alone and visible)."),
                                  "doc_id": docID]), readOnly: true) { a in
            let d = try doc(a, activate: false)
            var st = d.state
            var what = "“\(d.name)”"
            if a.has("layer_id") {
                var l = try layer(d, a)
                l.isVisible = true
                l.isClipped = false
                st.layers = [l]
                what = "layer “\(l.name)”"
            }
            guard let full = Compositor.shared.flatten(st) else { throw MCPToolError("The preview could not be rendered.") }
            let cg = fit(full, max: a.int("max_size") ?? 1024)
            guard let data = png(cg) else { throw MCPToolError("The preview could not be encoded.") }
            return .image(png: data, caption: "Preview of \(what): \(cg.width) × \(cg.height) px (document \(d.state.width) × \(d.state.height)).",
                          structured: ["width": cg.width, "height": cg.height, "document_width": d.state.width, "document_height": d.state.height])
        },

        MCPTool("get_selection", "Get Selection",
                "The current selection: whether there is one and its bounding box in document pixels.",
                schema: S.object(["doc_id": docID]), readOnly: true) { a in
            let d = try doc(a, activate: false)
            guard let b = d.state.selectionBounds else { return ok("No selection (edits apply to the whole layer).", ["has_selection": false]) }
            return ok("Selection bounds \(b.width) × \(b.height) at \(b.x), \(b.y).",
                      ["has_selection": true, "bounds": ["x": b.x, "y": b.y, "width": b.width, "height": b.height]])
        },

        MCPTool("get_history", "Get History",
                "The document's undo history (oldest first) and the current step.",
                schema: S.object(["doc_id": docID]), readOnly: true) { a in
            let d = try doc(a, activate: false)
            let steps = d.history.enumerated().map { i, e -> [String: Any] in ["index": i, "name": e.name, "current": i == d.historyIndex] }
            return ok("\(steps.count) history steps; current: “\(d.history[d.historyIndex].name)”.",
                      ["steps": steps, "current_index": d.historyIndex, "can_undo": d.canUndo, "can_redo": d.canRedo])
        },
    ]
}
