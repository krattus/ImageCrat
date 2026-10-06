import AppKit
import ImageCratCore

// MCP tools: brushes, automation (actions, JavaScript) and AI (on-device subject tools; paid generative fill behind
// the Preferences switch).

private typealias S = MCPSchema

extension MCPTools {
    // MARK: - Brushes

    static func brushRecord(_ key: String) -> BrushRecord? {
        let lib = BrushLibrary.shared
        if let r = lib.record(key) { return r }
        let all = lib.index.brushes.values.sorted { $0.name < $1.name }
        return all.first { $0.name == key } ?? all.first { $0.name.lowercased() == key.lowercased() } ?? all.first { norm($0.name) == norm(key) }
    }

    static let brushTools: [MCPTool] = [
        MCPTool("list_brushes", "List Brushes", "Brush presets in the brush library (id and name), for paint_stroke's `brush`.",
                schema: S.object(["filter": S.string("Only brushes whose name contains this."),
                                  "limit": S.integer("Maximum number of brushes.", min: 1, max: 5000, default: 300)]), readOnly: true) { a in
            let f = a.string("filter")?.lowercased()
            let all = BrushLibrary.shared.index.brushes.values.filter { f == nil || $0.name.lowercased().contains(f!) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let shown = all.prefix(a.int("limit") ?? 300).map { r -> [String: Any] in
                ["id": r.id, "name": r.name, "size": r.params.size, "tip": r.tipID, "source": r.source, "favorite": BrushLibrary.shared.isFavorite(r.id)]
            }
            return ok("\(all.count) brush\(all.count == 1 ? "" : "es")\(all.count > shown.count ? " (showing \(shown.count))" : "").", ["brushes": shown, "total": all.count])
        },

        MCPTool("paint_stroke", "Paint Stroke",
                "Paint one brush stroke through `points` on a pixel layer (inside the selection if there is one). Pressure (0–1) per point "
                + "varies the size. Without `layer_id`, a non-pixel active layer gets a new pixel layer “Paint” above it. `erase: true` erases instead.",
                schema: S.object(["points": S.array("The stroke path in document pixels.",
                                                    items: S.object(["x": S.number("X in pixels."), "y": S.number("Y in pixels."),
                                                                     "pressure": S.number("Pen pressure 0–1.", min: 0, max: 1)],
                                                                    required: ["x", "y"], description: "A point."), minItems: 1, maxItems: 10000),
                                  "brush": S.string("Brush preset id or name (see list_brushes). Default: a round brush."),
                                  "size": S.number("Brush diameter in pixels.", min: 1, max: 5000),
                                  "hardness": S.number("Edge hardness in percent (round brushes).", min: 0, max: 100),
                                  "opacity": S.number("Stroke opacity in percent.", min: 1, max: 100, default: 100),
                                  "spacing": S.number("Dab spacing in percent of the size.", min: 1, max: 1000),
                                  "color": S.color("Paint colour. Default: the foreground colour."),
                                  "erase": S.boolean("Erase instead of painting.", default: false),
                                  "layer_id": S.string("Pixel layer to paint on. Default: the active layer."), "doc_id": docID], required: ["points"])) { a in
            let d = try doc(a)
            var target: Layer
            if a.has("layer_id") {
                target = try layer(d, a)
                try pixelLayer(d, target, "paint_stroke")
            } else if let l = d.activeLayer, l.isRaster {
                target = l
            } else {
                let l = Layer.raster(name: d.nextLayerName("Paint"), width: d.state.width, height: d.state.height)
                d.addLayer(l, commitName: "New Layer")
                target = l
            }
            guard !target.locks.pixelsLocked else { throw MCPToolError("“\(target.name)” is locked.") }
            var s = BrushSettings()
            if let key = a.string("brush") {
                guard let r = brushRecord(key) else { throw MCPToolError("No brush “\(key)”. Use list_brushes for ids and names.") }
                s = BrushLibrary.shared.standaloneSettings(r)
            } else {
                s.size = 20; s.hardness = 0.8; s.spacing = 0.1
            }
            s.smoothing = 0
            if let v = a.double("size") { s.size = v }
            if let v = a.double("hardness") { s.hardness = v / 100 }
            if let v = a.double("spacing") { s.spacing = v / 100 }
            s.opacity = (a.double("opacity") ?? 100) / 100
            let raw = (a.array("points") ?? []).compactMap { $0 as? [String: Any] }
            let hasPressure = raw.contains { $0["pressure"] != nil }
            s.pressureSize = hasPressure
            let pts = raw.map { p in
                PenSample(p: CGPoint(x: MCPJSON.double(p["x"]) ?? 0, y: MCPJSON.double(p["y"]) ?? 0), pressure: MCPJSON.double(p["pressure"]) ?? 1)
            }
            let color = try a.color("color") ?? app.foreground
            let erase = a.bool("erase") == true
            select(d, target.id)
            guard let st = PaintStroke(doc: d, layerID: target.id, target: .content, opacity: s.opacity, blend: erase ? .destinationOut : .normal) else {
                throw MCPToolError("“\(target.name)” can't be painted on.")
            }
            let eng = BrushDynamicsEngine(settings: s, target: st.strokeBuf, origin: st.origin,
                                          paint: erase ? .fixed(.black) : .dynamic(fg: color, bg: app.background), seed: 42)
            st.dynamics = eng
            eng.begin(pts[0])
            st.flush()
            for (i, p) in pts.dropFirst().enumerated() {
                eng.move(p, final: i == pts.count - 2)
                if i % 8 == 0 { st.flush() }
            }
            st.finish(name: erase ? "Eraser" : "Brush")
            return resultLayer(d, target.id, "Painted a \(pts.count)-point stroke on “\(target.name)”.")
        },
    ]

    // MARK: - Automation

    static let scriptAPIDoc = """
    JavaScript (JavaScriptCore) with the ImageCrat scripting API. The value of the last expression and console.log output are returned. \
    Globals: app, Document, Layer, console. \
    app: documents, activeDocument, open(path), newDocument(w, h, name?, {background: 'white'|'transparent'|'#hex', resolution}), \
    filters(), adjustments(), foregroundColor / backgroundColor ('#RRGGBB'), listFiles(folder, exts?), readFile(path), writeFile(path, text). \
    Document: id, name, width, height, resolution, path, layers (top first, .getByName(n)), allLayers, activeLayer, selection, \
    addLayer(name?, {fill}), addGroup(name?), addTextLayer(text, {font, size, color, x, y, align, width, height}), \
    addShape('rectangle'|'ellipse'|'polygon'|'star'|'line', {x, y, width, height, fill, stroke, strokeWidth, radius, sides}), \
    addAdjustmentLayer(kind, params), placeFile(path, {x, y, width, height}), applyFilter(name, params), flatten(), mergeVisible(), \
    resizeImage(w, h, res?), resizeCanvas(w, h, anchor?), rotateCanvas(deg), flipCanvas(horizontal), undo(), redo(), duplicate(name?), \
    save(path?), exportAs(path, {format, quality, scale}), close(save?). \
    Layer: id, name, visible, opacity, fillOpacity, blendMode, kind, bounds, text (read/write), layers, setTextStyle({size, font, color}), \
    translate(dx, dy), rotate(deg), resize(sx%, sy%), duplicate(name?), remove(), applyFilter(name, params), adjust(kind, params), \
    rasterize(), moveAbove(l), moveBelow(l), select(), fill(color). \
    Selection: selectAll(), deselect(), rect(x, y, w, h, mode?), ellipse(x, y, w, h, mode?), invert(), bounds, fill(color, opacity?). \
    Dialogs (alert / prompt / confirm) don't block: they are logged. Example: \
    const d = app.activeDocument; const t = d.addTextLayer('Hi', {size: 64, x: 40, y: 40}); t.opacity = 80; d.layers.length
    """

    static let automationTools: [MCPTool] = [
        MCPTool("list_actions", "List Actions", "The recorded actions in the Actions panel, by set.",
                schema: S.object([:]), readOnly: true) { _ in
            let sets = ActionRecorder.shared.sets.map { set -> [String: Any] in
                ["set": set.name, "actions": set.actions.map { ["id": $0.id.uuidString, "name": $0.name, "steps": $0.steps.count] as [String: Any] }]
            }
            let n = ActionRecorder.shared.sets.reduce(0) { $0 + $1.actions.count }
            return ok("\(n) action\(n == 1 ? "" : "s").", ["sets": sets])
        },

        MCPTool("run_action", "Run Action", "Play a recorded action (Actions panel) on the active document; its steps are one undo step.",
                schema: S.object(["name": S.string("Action name or id (see list_actions).", minLength: 1), "doc_id": docID], required: ["name"])) { a in
            let d = try doc(a)
            guard let act = ActionPlayback.find(a.string("name")!) else { throw MCPToolError("No action “\(a.string("name")!)”. Use list_actions for the names.") }
            ActionPlayback.play(act)
            return ok("Played “\(act.name)” (\(act.steps.count) steps) on “\(d.name)”.", docJSON(d))
        },

        MCPTool("run_script", "Run Script", scriptAPIDoc,
                schema: S.object(["js": S.string("JavaScript source to run.", minLength: 1)], required: ["js"])) { a in
            var log: [String] = []
            let engine = ScriptEngine(name: "MCP", interactive: false)
            engine.log = { line in if log.count < 2000 { log.append(line) } }
            let savedHook = ScriptAPI.didWriteFile
            ScriptAPI.didWriteFile = { MCPServerController.shared.noteWrote($0) }   // files the script writes are logged like the tools'
            defer { ScriptAPI.didWriteFile = savedHook }
            let okRun = engine.evaluate(a.string("js")!)
            let out = log.joined(separator: "\n")
            if !okRun {
                return .error("Script error: \(engine.lastError ?? "unknown")" + (out.isEmpty ? "" : "\nOutput:\n" + out))
            }
            return ok(out.isEmpty ? "Script finished." : out, ["output": log])
        },
    ]

    // MARK: - AI

    static let paidRefusal = """
    generative_fill sends part of the image to a paid cloud service (fal.ai or another generative AI provider), and paid \
    generative calls from MCP are turned off. The user can allow them in \(Brand.name) ▸ Preferences ▸ Integrations ▸ \
    “Allow paid generative AI calls from MCP”. On-device alternatives: remove_background, select_subject, make_selection + fill.
    """

    static let aiTools: [MCPTool] = [
        MCPTool("remove_background", "Remove Background",
                "Hide the background of a layer with a layer mask from on-device subject detection (nothing leaves the Mac).",
                schema: S.object(["layer_id": layerID, "doc_id": docID])) { a in
            let d = try doc(a)
            let l = try layer(d, a)
            guard !l.isGroup && !l.isAdjustment else { throw MCPToolError("“\(l.name)” is a \(kind(l)) layer: pick the photo's layer.") }
            select(d, l.id)
            guard let m = AppActions.subjectMask() else { throw MCPToolError("No subject was found. Try a photo with a clear foreground subject.") }
            d.updateLayer(l.id) { $0.mask = LayerMask(buffer: m, origin: .zero, outsideValue: 0) }
            d.commit("Remove Background")
            return resultLayer(d, l.id, "Masked the background of “\(l.name)”.")
        },

        MCPTool("select_subject", "Select Subject", "Select the main subject of the image with on-device detection.",
                schema: S.object(["combine": S.string("How it combines with the current selection.", oneOf: SelectionCombine.allCases.map(\.rawValue), default: "new"),
                                  "doc_id": docID])) { a in
            let d = try doc(a)
            guard let m = AppActions.subjectMask() else { throw MCPToolError("No subject was found. Try a photo with a clear foreground subject.") }
            d.setSelection(SelectionOps.combine(d.state.selection, m, mode: combineMode(a)), commitName: "Select Subject")
            return ok("Subject selected.", selectionJSON(d))
        },

        MCPTool("generative_fill", "Generative Fill",
                "PAID, cloud: fill the selection (or `rect`) with generated content from a text prompt, as a new layer. Refused unless the user "
                + "allowed paid generative AI calls from MCP in Preferences ▸ Integrations; the app may ask the user to confirm the cost.",
                schema: S.object(["prompt": S.string("What to generate (empty: fill in plausibly).", default: ""),
                                  "rect": S.rect("Area to fill. Default: the current selection."), "doc_id": docID]), openWorld: true) { a, done in
            let settings = MCPServerController.shared.settings
            guard settings.allowPaidGenerative else { throw MCPToolError(paidRefusal) }
            let d = try doc(a)
            if let r = a.rect("rect") {
                guard r.width >= 1, r.height >= 1 else { throw MCPToolError("`rect` must be at least 1 × 1.") }
                d.setSelection(rectMask(d, r), commitName: "Rectangular Marquee")
            }
            guard let sel = d.state.selection, sel.opaqueBounds() != nil else { throw MCPToolError("Make a selection first (make_selection) or pass `rect`.") }
            let model: GenModel
            do { model = try ProviderRouter.shared.resolve(.fill).1 } catch {
                throw MCPToolError("No generative AI provider is set up for Generative Fill (Preferences ▸ Generative AI): \(error.localizedDescription)")
            }
            let prompt = a.string("prompt") ?? ""
            if !settings.skipPaidConfirmation {
                let al = NSAlert()
                al.messageText = tr("Run a paid Generative Fill for an MCP client?")
                al.informativeText = tr("An MCP client (such as Claude Code) asks for Generative Fill with \(model.provider.displayName) (\(model.name)). Estimated cost: \(GenBudget.estimateText(model, count: max(1, GenAISettings.shared.data.variations))).")
                    + (prompt.isEmpty ? "" : "\n\n" + tr("Prompt: \(prompt)"))
                al.addButton(withTitle: tr("Generate"))
                al.addButton(withTitle: tr("Cancel"))
                al.showsSuppressionButton = true
                al.suppressionButton?.title = tr("Don't ask again for MCP")
                let r = UIBlock.run(al)
                if al.suppressionButton?.state == .on && r == .alertFirstButtonReturn { MCPServerController.shared.settings.skipPaidConfirmation = true }
                guard r == .alertFirstButtonReturn else { throw MCPToolError("The user declined the paid Generative Fill.") }
            }
            GenJobs.shared.lastError = nil
            GenPipeline.runRegion(d, feature: .fill, prompt: prompt, sel: sel, layerName: prompt.isEmpty ? "Generative Fill" : String(prompt.prefix(40)), after: { id in
                if let id { done(resultLayer(d, id, "Generative Fill added “\(d.state.layer(id)?.name ?? "")”.")) }
                else { done(.error("Generative Fill failed: \(GenJobs.shared.lastError ?? "the job was cancelled or the provider returned an error").")) }
            })
        },
    ]
}
