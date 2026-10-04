import AppKit
import Observation
import ImageCratCore

/// Global "sampling hook": while armed, the next canvas mouse-down is delivered here (doc coordinates)
/// instead of the current tool. Used by adjustment eyedroppers (Levels/Curves/Hue-Sat/Replace Color).
@Observable
final class CanvasSampler {
    static let shared = CanvasSampler()

    /// Identifies the armed dropper (for button highlighting); nil when idle.
    private(set) var token: String?
    @ObservationIgnored private var handler: ((CGPoint, NSEvent.ModifierFlags) -> Void)?

    var isArmed: Bool { token != nil }

    func arm(_ token: String, _ handler: @escaping (CGPoint, NSEvent.ModifierFlags) -> Void) {
        self.token = token
        self.handler = handler
        AppModel.shared.setStatus("Click in the image to sample")
    }

    /// Disarms (only if `token` matches the armed one, when given).
    func disarm(_ token: String? = nil) {
        guard token == nil || token == self.token else { return }
        self.token = nil
        handler = nil
    }

    func toggle(_ token: String, _ handler: @escaping (CGPoint, NSEvent.ModifierFlags) -> Void) {
        if self.token == token { disarm() } else { arm(token, handler) }
    }

    /// Called from CanvasView.mouseDown. Returns true when the click was consumed.
    func handle(_ docPoint: CGPoint, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let h = handler else { return false }
        h(docPoint, modifiers)
        return true
    }
}
