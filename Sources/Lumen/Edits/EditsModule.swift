import SwiftUI
import ImageCratCore

/// Adjustments / selection / retouching / transform / lens features (menus, dialogs, panels, self tests).
enum EditsModule {
    static func register() {
        // Destructive versions of the Camera Raw style adjustments.
        for k in AdjustmentKind.editsLayerKinds {
            MenuRegistry.add("Image", k.displayName + "…", submenu: "Camera Raw Adjustments") { AppModel.shared.dialog = .adjustment(k) }
        }
        Matting.register()
        ContentAwareFillEngine.register()
        CloneSourcesModule.register()
        VanishingPointModule.register()
        UpscalerRegistry.registerBuiltIns()
        AdaptiveWideAngleModule.register()
        EditsSelfTests.register()
    }
}
