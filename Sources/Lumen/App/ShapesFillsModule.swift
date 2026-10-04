import Foundation
import ImageCratCore

/// Shapes & fill layers: stroke options (dashes, presets), the fill layer dialogs, shape × vector mask commands and the
/// `shapesfills` self test (`LUMEN_SELFTEST_ONLY=shapesfills Lumen --selftest <dir>`).
enum ShapesFillsModule {
    static func register() {
        FillLayerDialog.register()
        MenuRegistry.add("Layer", "Intersect Shape with Vector Mask", enabled: {
            guard let l = AppActions.doc?.activeLayer else { return false }
            return l.isShape && !(l.vectorMask?.isEmpty ?? true)
        }) {
            guard let d = AppActions.doc, let id = d.activeLayerID else { return }
            ShapeMaskOps.intersectWithVectorMask(d, id)
        }
        MenuRegistry.add("Layer", "Fill Layer Options…", enabled: {
            guard let f = AppActions.doc?.activeLayer?.fill else { return false }
            return f.recipe == nil
        }) {
            guard let id = AppActions.doc?.activeLayerID else { return }
            FillLayerDialog.open(id)
        }
        FeatureModules.selfTests.append(("shapesfills", { ShapesFillsSelfTest.run($0) }))
    }
}
