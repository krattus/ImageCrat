import SwiftUI
import AppKit
import ImageCratCore

/// Named adjustment presets per kind: Photoshop-like built-ins plus user presets saved as JSON in UserDefaults.
enum AdjustmentPresets {
    struct Preset: Codable, Equatable {
        var name: String
        var settings: AdjustmentSettings
    }

    static func defaultsKey(_ k: AdjustmentKind) -> String { "Lumen.adjustmentPresets.\(k.rawValue)" }

    static func userPresets(_ k: AdjustmentKind, defaults: UserDefaults = .standard) -> [Preset] {
        guard let data = defaults.data(forKey: defaultsKey(k)),
              let list = try? JSONDecoder().decode([Preset].self, from: data) else { return [] }
        return list.filter { $0.settings.kind == k }
    }

    static func setUserPresets(_ list: [Preset], for k: AdjustmentKind, defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: defaultsKey(k)) }
    }

    static func save(_ name: String, _ s: AdjustmentSettings, defaults: UserDefaults = .standard) {
        var list = userPresets(s.kind, defaults: defaults)
        list.removeAll { $0.name == name }
        list.append(Preset(name: name, settings: s))
        setUserPresets(list, for: s.kind, defaults: defaults)
    }

    static func delete(_ name: String, kind: AdjustmentKind, defaults: UserDefaults = .standard) {
        var list = userPresets(kind, defaults: defaults)
        list.removeAll { $0.name == name }
        setUserPresets(list, for: kind, defaults: defaults)
    }

    // MARK: Built-ins

    private static func mk(_ k: AdjustmentKind, _ f: (inout AdjustmentSettings) -> Void) -> AdjustmentSettings {
        var s = AdjustmentSettings(kind: k); f(&s); return s
    }
    private static func pts(_ p: [(Double, Double)]) -> CurvePoints { CurvePoints(points: p.map { CGPoint(x: $0.0 / 255, y: $0.1 / 255) }) }

    static func builtIn(_ k: AdjustmentKind) -> [Preset] {
        func p(_ n: String, _ f: (inout AdjustmentSettings) -> Void) -> Preset { Preset(name: n, settings: mk(k, f)) }
        switch k {
        case .levels:
            return [
                p("Darker") { $0.levels[0].outWhite = 210; $0.levels[0].gamma = 0.88 },
                p("Increase Contrast 1") { $0.levels[0].inBlack = 10; $0.levels[0].inWhite = 245 },
                p("Increase Contrast 2") { $0.levels[0].inBlack = 20; $0.levels[0].inWhite = 235 },
                p("Increase Contrast 3") { $0.levels[0].inBlack = 30; $0.levels[0].inWhite = 225 },
                p("Lighten Shadows") { $0.levels[0].gamma = 1.6; $0.levels[0].outBlack = 20 },
                p("Lighter") { $0.levels[0].inWhite = 230; $0.levels[0].gamma = 1.1 },
                p("Midtones Brighter") { $0.levels[0].gamma = 1.25 },
                p("Midtones Darker") { $0.levels[0].gamma = 0.8 },
            ]
        case .curves:
            return [
                p("Color Negative (RGB)") {
                    $0.curves[1] = pts([(0, 255), (255, 0)]); $0.curves[2] = pts([(0, 255), (255, 20)]); $0.curves[3] = pts([(0, 230), (255, 40)])
                },
                p("Cross Process (RGB)") {
                    $0.curves[1] = pts([(0, 0), (64, 40), (192, 220), (255, 255)])
                    $0.curves[2] = pts([(0, 0), (64, 56), (192, 212), (255, 255)])
                    $0.curves[3] = pts([(0, 30), (255, 225)])
                },
                p("Darker (RGB)") { $0.curves[0] = pts([(0, 0), (140, 100), (255, 255)]) },
                p("Increase Contrast (RGB)") { $0.curves[0] = pts([(0, 0), (64, 52), (192, 204), (255, 255)]) },
                p("Lighter (RGB)") { $0.curves[0] = pts([(0, 0), (115, 155), (255, 255)]) },
                p("Linear Contrast (RGB)") { $0.curves[0] = pts([(0, 0), (48, 36), (208, 220), (255, 255)]) },
                p("Medium Contrast (RGB)") { $0.curves[0] = pts([(0, 0), (64, 46), (192, 210), (255, 255)]) },
                p("Negative (RGB)") { $0.curves[0] = pts([(0, 255), (255, 0)]) },
                p("Strong Contrast (RGB)") { $0.curves[0] = pts([(0, 0), (64, 36), (192, 222), (255, 255)]) },
            ]
        case .hueSaturation:
            return [
                p("Cyanotype") { $0.colorize = true; $0.hue = -160; $0.hsSaturation = 25 },
                p("Increase Red Saturation") { $0.hsRanges[0].saturation = 30 },
                p("Old Style") { $0.colorize = true; $0.hue = 38; $0.hsSaturation = -40; $0.lightness = -5 },
                p("Red Boost") { $0.hsRanges[0].saturation = 40; $0.hsRanges[0].lightness = -5 },
                p("Sepia") { $0.colorize = true; $0.hue = 35; $0.hsSaturation = 0 },
                p("Strong Saturation") { $0.hsSaturation = 45 },
                p("Yellow Boost") { $0.hsRanges[1].saturation = 40; $0.hsRanges[1].lightness = 5 },
            ]
        case .blackWhite:
            func bw(_ n: String, _ v: [Double]) -> Preset {
                p(n) { s in s.bwReds = v[0]; s.bwYellows = v[1]; s.bwGreens = v[2]; s.bwCyans = v[3]; s.bwBlues = v[4]; s.bwMagentas = v[5] }
            }
            return [
                bw("Default", [40, 60, 40, 60, 20, 80]),
                bw("Blue Filter", [0, 0, 0, 110, 110, 110]),
                bw("Darker", [20, 40, 20, 40, 0, 60]),
                bw("Green Filter", [40, 80, 120, 60, 20, 30]),
                bw("High Contrast Blue Filter", [-50, -50, 120, 120, 120, 120]),
                bw("High Contrast Red Filter", [120, 120, -10, -50, -50, 120]),
                bw("Infrared", [-40, 235, 144, -68, -3, -107]),
                bw("Lighter", [60, 80, 60, 80, 40, 100]),
                bw("Maximum Black", [0, 0, 0, 0, 0, 0]),
                bw("Maximum White", [100, 100, 100, 100, 100, 100]),
                bw("Neutral Density", [128, 128, 100, 100, 128, 100]),
                bw("Red Filter", [120, 110, -10, -50, -50, 120]),
                bw("Yellow Filter", [120, 110, 40, -30, -50, 90]),
            ]
        case .exposure:
            return [
                p("Minus 1.0") { $0.exposure = -1 },
                p("Minus 2.0") { $0.exposure = -2 },
                p("Plus 1.0") { $0.exposure = 1 },
                p("Plus 2.0") { $0.exposure = 2 },
            ]
        case .colorWB:
            return [
                p("Warm") { $0.params = ["temperature": 30, "tint": 5] },
                p("Cool") { $0.params = ["temperature": -30, "tint": -3] },
                p("Tungsten Correction") { $0.params = ["temperature": -55, "tint": 4] },
                p("Golden") { $0.params = ["temperature": 45, "tint": 10, "vibrance": 20] },
                p("Punchy") { $0.params = ["vibrance": 35, "saturation": 10] },
                p("Muted") { $0.params = ["vibrance": -30, "saturation": -15] },
            ]
        case .light:
            return [
                p("Recover Highlights") { $0.params = ["highlights": -80, "whites": -20] },
                p("Open Shadows") { $0.params = ["shadows": 70, "blacks": 10] },
                p("HDR Look") { $0.params = ["highlights": -90, "shadows": 80, "contrast": 20, "whites": 20, "blacks": -20] },
                p("Bright & Airy") { $0.params = ["exposure": 0.6, "contrast": -20, "shadows": 40] },
                p("Low Key") { $0.params = ["exposure": -0.7, "contrast": 30, "blacks": -30] },
            ]
        case .clarity:
            return [p("Crisp") { $0.params = ["amount": 45] }, p("Soft Glow") { $0.params = ["amount": -50] }]
        case .dehaze:
            return [p("Clear Haze") { $0.params = ["amount": 45] }, p("Add Mist") { $0.params = ["amount": -40] }]
        case .grain:
            return [
                p("Fine Film") { $0.params = ["amount": 18, "size": 10, "roughness": 40] },
                p("Coarse Film") { $0.params = ["amount": 40, "size": 60, "roughness": 70] },
            ]
        default:
            return []
        }
    }

    /// Name of the preset (built-in first) whose settings equal `s`, if any.
    static func matching(_ s: AdjustmentSettings) -> String? {
        if s == AdjustmentSettings(kind: s.kind) { return "Default" }
        return (builtIn(s.kind) + userPresets(s.kind)).first { $0.settings == s }?.name
    }

    /// Asks for a preset name.
    static func promptName(_ suggested: String) -> String? {
        let a = NSAlert()
        a.messageText = tr("Save Adjustment Preset")
        a.informativeText = tr("Name:")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tf.stringValue = suggested
        a.accessoryView = tf
        a.addButton(withTitle: tr("Save"))
        a.addButton(withTitle: tr("Cancel"))
        a.window.initialFirstResponder = tf
        guard UIBlock.run(a) == .alertFirstButtonReturn else { return nil }
        let n = tf.stringValue.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }
}

/// Preset picker shown at the top of the adjustment controls (Properties panel and destructive dialogs).
struct AdjustmentPresetPicker: View {
    @Binding var s: AdjustmentSettings
    var onCommit: () -> Void
    @State private var tick = 0

    var body: some View {
        let _ = tick
        let builtIns = AdjustmentPresets.builtIn(s.kind)
        let user = AdjustmentPresets.userPresets(s.kind)
        HStack(spacing: 6) {
            Text("Preset").foregroundStyle(Theme.textDim)
            Menu(tr(AdjustmentPresets.matching(s) ?? "Custom")) {
                Button("Default") { load(AdjustmentSettings(kind: s.kind)) }
                if !builtIns.isEmpty {
                    Divider()
                    ForEach(builtIns, id: \.name) { p in Button(tr(p.name)) { load(p.settings) } }
                }
                if !user.isEmpty {
                    Divider()
                    ForEach(user, id: \.name) { p in Button(tr(p.name)) { load(p.settings) } }
                }
                Divider()
                Button("Save Preset…") {
                    if let n = AdjustmentPresets.promptName("\(s.kind.displayName) Preset \(user.count + 1)") {
                        AdjustmentPresets.save(n, s); tick += 1
                    }
                }
                if !user.isEmpty {
                    Menu("Delete Preset") {
                        ForEach(user, id: \.name) { p in Button(tr(p.name)) { AdjustmentPresets.delete(p.name, kind: s.kind); tick += 1 } }
                    }
                }
            }
            .frame(maxWidth: 200)
        }
    }

    func load(_ p: AdjustmentSettings) {
        // Keep data a preset doesn't own (e.g. sampled colors of Replace Color).
        var n = p
        n.kind = s.kind
        s = n
        onCommit()
    }
}
