import SwiftUI
import ImageCratCore

/// Feature module: AI object selection (SAM 2.1), text prompts (Florence-2 / SAM 3.1), hair matting (BiRefNet).
///
/// Menus: Select ▸ Subject (High Quality), People ▸ …, Mask All Objects, Select by Description…;
/// Layer ▸ Mask All Objects. Built-in Select ▸ Subject / Sky / Remove Background route here when SAM is installed.
enum ObjectSelectionModule {
    static let describeDialog = "objsel.describe"

    static func register() {
        SegModels.registerSpecs()
        DialogRegistry.register(describeDialog, dims: false) { AnyView(SelectByDescriptionDialog()) }
        let hasDoc = { AppActions.doc != nil }
        MenuRegistry.add("Select", "Subject (High Quality)", dividerBefore: true, enabled: hasDoc) { selectSubjectOrExplain(quality: .high) }
        MenuRegistry.add("Select", "Select by Description…", enabled: hasDoc) { DialogRegistry.show(describeDialog) }
        MenuRegistry.add("Select", "Mask All Objects", enabled: hasDoc) { maskAllObjects() }
        MenuRegistry.add("Select", "All People", submenu: "People", enabled: hasDoc) { selectPeople(index: nil) }
        for i in 1...4 {
            MenuRegistry.add("Select", "Person \(i)", submenu: "People", enabled: hasDoc) { selectPeople(index: i - 1) }
        }
        MenuRegistry.add("Select", "Faces", submenu: "People", enabled: hasDoc) { selectFaces() }
        MenuRegistry.add("Layer", "Mask All Objects", dividerBefore: true, enabled: hasDoc) { maskAllObjects() }
        FeatureModules.selfTests.append(("objsel", { ObjSelSelfTest.run($0) }))
    }

    static var settings: ObjectSelectionSettings { .shared }
    static var engine: ObjectSelectionEngine { .shared }

    // MARK: Routed built-ins (return false to fall back to the original Vision implementation)

    /// Select ▸ Subject. Returns false when SAM isn't installed (caller then runs the Vision implementation).
    @discardableResult
    static func selectSubject(quality: SegMatting.Quality? = nil) -> Bool {
        guard SegModels.samInstalled, AppActions.doc != nil else { return false }
        let q = quality ?? settings.subjectQuality
        let hair = settings.hairEdges || q == .high
        engine.run(q == .high ? "Selecting subject (High Quality)…" : "Selecting subject…", { img in
            try SegmentationService.subjectSync(img, quality: q, hair: hair)
        }, done: { m in
            guard let d = AppActions.doc else { return }
            guard let m else { AppActions.alert("No subject was found.", "Try a photo with a clear foreground subject."); return }
            d.setSelection(m, commitName: "Select Subject")
        })
        return true
    }

    /// Select ▸ Subject (High Quality) and the options-bar button: SAM only, so without it say what to download.
    static func selectSubjectOrExplain(quality: SegMatting.Quality?) {
        guard AppActions.doc != nil, !selectSubject(quality: quality) else { return }
        let msg = ModelManager.shared.missingMessage(SegModels.sam2)
        AppModel.shared.setStatus(msg)
        AppActions.alert("Select Subject needs the SAM 2.1 model.", msg + " Select ▸ Subject also works without it (built-in, lower quality).")
    }

    /// Select ▸ Remove Background (subject mask as the layer mask).
    @discardableResult
    static func removeBackground() -> Bool {
        guard SegModels.samInstalled, let d = AppActions.doc, let id = d.activeLayerID else { return false }
        let hair = settings.hairEdges || settings.subjectQuality == .high
        engine.run("Removing background…", { img in
            try SegmentationService.subjectSync(img, quality: settings.subjectQuality, hair: hair)
        }, done: { m in
            guard let m else { AppActions.alert("No subject was found."); return }
            d.updateLayer(id) { $0.mask = LayerMask(buffer: m, origin: .zero, outsideValue: 0) }
            d.commit("Remove Background")
        })
        return true
    }

    /// Select ▸ Sky.
    @discardableResult
    static func selectSky() -> Bool {
        guard SegModels.samInstalled || SegModels.florenceInstalled, AppActions.doc != nil else { return false }
        engine.run("Selecting sky…", { img in try SegmentationService.skySync(img) }, done: { m in
            guard let d = AppActions.doc else { return }
            guard let m, m.opaqueBounds(threshold: 20) != nil else { AppActions.alert("No sky was found."); return }
            d.setSelection(m, commitName: "Select Sky")
        })
        return true
    }

    // MARK: People

    static func selectPeople(index: Int?) {
        guard AppActions.doc != nil else { return }
        let hair = settings.hairEdges || SegMatting.isAvailable
        engine.run("Finding people…", { img in try SegmentationService.peopleSync(img, hair: hair) }, done: { people in
            guard let d = AppActions.doc else { return }
            guard let people, !people.isEmpty else { AppActions.alert("No people were found."); return }
            if let i = index {
                guard i < people.count else { AppActions.alert("Person \(i + 1) was not found.", "\(people.count) \(people.count == 1 ? "person was" : "people were") detected (numbered left to right)."); return }
                d.setSelection(people[i], commitName: "Select Person \(i + 1)")
            } else if let u = SegMask.union(people) {
                d.setSelection(u, commitName: "Select People")
            }
        })
    }

    static func selectFaces() {
        guard AppActions.doc != nil else { return }
        engine.run("Finding faces…", { img -> PixelBuffer? in
            let faces = SegmentationService.faceBoxes(img)
            guard !faces.isEmpty else { return nil }
            var masks: [PixelBuffer] = []
            for f in faces {
                if SAMSegmenter.shared.isAvailable, let m = try SegmentationService.boxSync(img, box: f, points: [(CGPoint(x: f.midX, y: f.midY), .positive)], options: settings.options) {
                    masks.append(m)
                } else {
                    masks.append(SelectionOps.mask(fromPath: CGPath(ellipseIn: f, transform: nil), width: img.width, height: img.height))
                }
            }
            return SegMask.union(masks)
        }, done: { m in
            guard let d = AppActions.doc else { return }
            guard let m else { AppActions.alert("No faces were found."); return }
            d.setSelection(m, commitName: "Select Faces")
        })
    }

    // MARK: Text prompts

    static func find(_ text: String, mode: SelectionCombine) {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let d = AppActions.doc, let img = engine.prepare(d) else { return }
        guard SegModels.florenceInstalled || SAM3Engine.isAvailable else {
            AppModel.shared.setStatus("Text prompts need the Florence-2 model — use “Get text model” in the options bar.")
            NSSound.beep(); return
        }
        settings.busy = "Finding “\(t)”…"
        let engineChoice = settings.textEngine, opts = settings.options
        Task {
            do {
                let matches = try await SegmentationService.textMatches(t, in: img, engine: engineChoice, options: opts)
                await MainActor.run {
                    settings.busy = nil
                    guard let u = SegMask.union(matches.map(\.mask)) else {
                        AppModel.shared.setStatus("Nothing matching “\(t)” was found."); NSSound.beep(); return
                    }
                    d.setSelection(SelectionOps.combine(d.state.selection, u, mode: mode), commitName: "Select “\(t)”")
                    AppModel.shared.setStatus("Selected \(matches.count) match(es) for “\(t)”.")
                }
            } catch {
                await MainActor.run { settings.busy = nil; AppModel.shared.setStatus(error.localizedDescription); NSSound.beep() }
            }
        }
    }

    // MARK: Mask All Objects

    /// Creates a group “Objects” containing one empty group per detected object, each with the object's layer mask
    /// (Photoshop-style masked groups: drop layers/adjustments into a group to affect only that object, or
    /// ⌘-click its mask to load the selection). The document's appearance doesn't change.
    static func maskAllObjects() {
        guard let d = AppActions.doc else { return }
        guard SegModels.samInstalled else {
            AppActions.alert("Mask All Objects needs the SAM 2.1 model.", "Download it in the Object Selection tool's options bar or Preferences ▸ AI Models.")
            return
        }
        engine.run("Masking all objects…", { img in try SegmentationService.allObjectsSync(img, grid: 32).map(\.1) }, done: { masks in
            guard let masks, !masks.isEmpty else { AppActions.alert("No objects were found."); return }
            let n = createObjectGroups(d, masks: masks)
            AppModel.shared.setStatus("Created \(n) masked object groups.")
        })
    }

    @discardableResult
    static func createObjectGroups(_ d: Document, masks: [PixelBuffer]) -> Int {
        var children: [Layer] = []
        for (i, m) in masks.enumerated().reversed() {
            var g = Layer(name: "Object \(i + 1)", content: .group(GroupContent()))
            g.mask = LayerMask(buffer: m, origin: .zero, outsideValue: 0)
            children.append(g)
        }
        let parent = Layer(name: "Objects", content: .group(GroupContent(children: children, isExpanded: true)))
        d.state.insertLayer(parent, above: d.activeLayerID)
        d.activeLayerID = parent.id
        d.selectedLayerIDs = [parent.id]
        d.commit("Mask All Objects")
        return children.count
    }

    // MARK: Select and Mask ▸ Refine Hair

    /// Runs hair/edge matting on `mask` (or the current selection) and returns the refined mask via `done`.
    static func refineHair(mask: PixelBuffer?, quality: SegMatting.Quality? = nil, done: @escaping (PixelBuffer?) -> Void) {
        guard let d = AppActions.doc else { done(nil); return }
        guard SegMatting.isAvailable else {
            AppActions.alert("Refine Hair needs a BiRefNet matting model.", "Download “BiRefNet Lite” (92 MB) or “BiRefNet” (470 MB) in Preferences ▸ AI Models.")
            done(nil); return
        }
        let base = mask ?? d.state.selection
        guard let base else { NSSound.beep(); done(nil); return }
        let q = quality ?? settings.hairQuality
        engine.run("Refining hair…", { img in try SegMatting.refine(mask: base, image: img, quality: q) }, done: done)
    }
}
