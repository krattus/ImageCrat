import SwiftUI
import AppKit
import ImageCratCore

/// Node-based Recipe layers / filters and procedural texture generators.
///
/// Storage: a Recipe layer is a fill layer whose `FillContent.recipe` holds a `RecipeGraph`; a Recipe smart filter is a
/// `FilterInstance` of kind `.recipe` with the graph in `FilterInstance.recipe`. Rendering goes through
/// `RecipeRuntime.shared.layerContent` / `.smartFilter` (called from `Compositor.contentImage` / `FilterInstance.apply`).
enum NodesModule {
    static func register() {
        FeatureModules.selfTests.append(("nodes", { out in NodesSelfTest.run(out) }))

        let hasDoc = { AppModel.shared.activeDocument != nil }
        let hasRecipe = { AppModel.shared.activeDocument?.activeLayer.flatMap { RecipeActions.target(for: $0) } != nil }

        // Layer ▸ New ▸ Recipe Layer…
        MenuRegistry.add("Layer/New", "Recipe Layer…", enabled: hasDoc) { DialogRegistry.show("recipeNewLayer") }
        MenuRegistry.add("Layer", "Edit Recipe…", submenu: "Recipe", enabled: hasRecipe) { RecipeActions.openEditor() }
        MenuRegistry.add("Layer", "New Recipe Layer…", submenu: "Recipe", enabled: hasDoc) { DialogRegistry.show("recipeNewLayer") }
        MenuRegistry.add("Layer", "Rasterize Recipe Layer", submenu: "Recipe", enabled: { AppModel.shared.activeDocument?.activeLayer?.isRecipe == true }) { RecipeActions.rasterize() }
        MenuRegistry.add("Layer", "Save Recipe as Preset", submenu: "Recipe", enabled: hasRecipe) {
            guard let d = AppModel.shared.activeDocument, let l = d.activeLayer, let t = RecipeActions.target(for: l), let g = d.state.recipeGraph(t) else { return }
            if (try? RecipePresetStore.shared.save(name: g.name, graph: g)) != nil { AppModel.shared.setStatus("Saved recipe “\(g.name)”.") }
        }

        // Filter ▸ Recipe Filter…
        // (a recipe filter is a smart filter: needs a smart object, or layers that can become one)
        MenuRegistry.add("Filter", "Recipe Filter…", dividerBefore: true,
                         enabled: { AppActions.doc?.activeLayer?.isSmartObject == true || AppActions.canConvertToSmartObject }) { DialogRegistry.show("recipeNewFilter") }

        // Filter ▸ Render ▸ Textures ▸ …
        MenuRegistry.add("Filter/Render", "Texture Generator…", submenu: "Textures", enabled: hasDoc) { TextureDialogModel.shared.start(nil); DialogRegistry.show("texture") }
        for cat in TextureCategory.allCases {
            for (i, g) in TextureCatalog.byCategory(cat).enumerated() {
                MenuRegistry.add("Filter/Render", g.name + "…", submenu: "Textures", dividerBefore: i == 0, enabled: hasDoc) {
                    TextureDialogModel.shared.start(g.id)
                    DialogRegistry.show("texture")
                }
            }
        }
        let utilities: [(String, String)] = [("util.normal", "Normal Map from Height…"), ("util.ao", "Ambient Occlusion…"),
                                             ("util.seamless", "Make Seamless Tile…"), ("util.gradientMap", "Color Ramp Mapping…")]
        for (i, u) in utilities.enumerated() {
            MenuRegistry.add("Filter/Render", u.1, submenu: "Textures", dividerBefore: i == 0, enabled: hasDoc) {
                RecipeNodeFilterModel.shared.start(u.0)
                DialogRegistry.show("recipeNodeFilter")
            }
        }

        MenuRegistry.add("Window", "Recipe Editor", enabled: hasRecipe) { RecipeActions.openEditor() }

        DialogRegistry.register("recipeNewLayer") { AnyView(RecipePresetDialog(asFilter: false)) }
        DialogRegistry.register("recipeNewFilter") { AnyView(RecipePresetDialog(asFilter: true)) }
        DialogRegistry.register("texture", dims: false) { AnyView(TextureDialog()) }
        DialogRegistry.register("recipeNodeFilter", dims: false) { AnyView(RecipeNodeFilterDialog()) }

        PanelRegistry.register(PanelRegistry.Def(id: "recipes", title: "Recipes") { AnyView(RecipesPanel()) })

        // Fast path for iterating on this module only: LUMEN_NODES_SELFTEST=<outdir> runs just these tests and exits.
        if let dir = ProcessInfo.processInfo.environment["LUMEN_NODES_SELFTEST"], !dir.isEmpty {
            let out = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            _ = NSApplication.shared
            NodesSelfTest.run(out)
            exit(NodesSelfTest.failures == 0 ? 0 : 1)
        }
    }
}
