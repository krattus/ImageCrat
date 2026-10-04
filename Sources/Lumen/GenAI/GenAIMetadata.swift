import Foundation
import CoreGraphics
import ImageCratCore
extension Document {
    func generativeInfo(_ id: UUID?) -> GenerativeLayerInfo? {
        guard let id else { return nil }
        return state.generative[id]
    }
}
