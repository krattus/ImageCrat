import Foundation
import ImageCratCore

/// Connects ImageCratCore to the Mac implementations it cannot contain (Core Graphics pixel storage, component
/// image overrides). Runs first thing at launch, before any document or pixel buffer exists.
enum CorePlatform {
    static func install() {
        CGBitmapPixelStorage.install()
        ComponentCodec.refreshInstances = { st in _ = ComponentEngine.refresh(&st.layers, table: st.components, only: nil) }
    }
}
