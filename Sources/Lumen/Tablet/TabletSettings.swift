import Foundation
import Observation
import ImageCratCore

/// Photoshop's Smoothing options (the gear next to Smoothing in the options bar).
struct SmoothingOptions: Codable, Equatable {
    /// The paint only moves while the string is taut.
    var pulledString = false
    /// While the pen rests, the paint keeps catching up with it.
    var strokeCatchUp = true
    /// Releasing the pen finishes the stroke at the pen position.
    var catchUpOnEnd = true
    /// The string length is in screen pixels (shorter in document pixels when zoomed in).
    var adjustForZoom = true

    init() {}
    private enum K: String, CodingKey { case pulledString, strokeCatchUp, catchUpOnEnd, adjustForZoom }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        pulledString = (try? c.decodeIfPresent(Bool.self, forKey: .pulledString)) ?? false
        strokeCatchUp = (try? c.decodeIfPresent(Bool.self, forKey: .strokeCatchUp)) ?? true
        catchUpOnEnd = (try? c.decodeIfPresent(Bool.self, forKey: .catchUpOnEnd)) ?? true
        adjustForZoom = (try? c.decodeIfPresent(Bool.self, forKey: .adjustForZoom)) ?? true
    }
}

/// Preferences ▸ Tablet (and the input ergonomics that go with it). Remembered per user.
struct TabletPrefs: Codable, Equatable {
    /// Pen pressure response (curve and min/max output).
    var curve = PressureCurve()
    /// How strongly pen tilt counts (1 = as reported; 2 = a slight lean already reads as fully tilted).
    var tiltSensitivity: Double = 1
    /// Turning the pen over switches to the Eraser (and back).
    var usePenEraser = true
    /// Light low-pass filter on pressure and tilt (noisy or old tablets).
    var smoothInput = false
    /// Default of the options-bar pressure buttons for every painting tool.
    var pressureSizeDefault = true
    var pressureOpacityDefault = false
    /// Force Touch trackpads: the click force is used as pressure.
    var forceTouchPressure = false
    var smoothing = SmoothingOptions()
    /// Painting tools share one brush tip (size, hardness, shape) instead of each remembering its own.
    var syncBrushAcrossTools = false
    /// Favourite and recent preset ids the quick brush picker kept before it used the brush library (which now holds
    /// both). Decoded from the old keys, merged into the library once (`migrateBrushLists`), then dropped.
    var legacyFavoriteBrushes: [String] = []
    var legacyRecentBrushes: [String] = []

    init() {}

    private enum K: String, CodingKey {
        case curve, tiltSensitivity, usePenEraser, smoothInput, pressureSizeDefault, pressureOpacityDefault, forceTouchPressure
        case smoothing, syncBrushAcrossTools, favoriteBrushes, recentBrushes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let d = TabletPrefs()
        func v<T: Decodable>(_ k: K, _ def: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? def }
        curve = v(.curve, d.curve)
        tiltSensitivity = v(.tiltSensitivity, d.tiltSensitivity)
        usePenEraser = v(.usePenEraser, d.usePenEraser)
        smoothInput = v(.smoothInput, d.smoothInput)
        pressureSizeDefault = v(.pressureSizeDefault, d.pressureSizeDefault)
        pressureOpacityDefault = v(.pressureOpacityDefault, d.pressureOpacityDefault)
        forceTouchPressure = v(.forceTouchPressure, d.forceTouchPressure)
        smoothing = v(.smoothing, d.smoothing)
        syncBrushAcrossTools = v(.syncBrushAcrossTools, d.syncBrushAcrossTools)
        legacyFavoriteBrushes = v(.favoriteBrushes, d.legacyFavoriteBrushes)
        legacyRecentBrushes = v(.recentBrushes, d.legacyRecentBrushes)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(curve, forKey: .curve)
        try c.encode(tiltSensitivity, forKey: .tiltSensitivity)
        try c.encode(usePenEraser, forKey: .usePenEraser)
        try c.encode(smoothInput, forKey: .smoothInput)
        try c.encode(pressureSizeDefault, forKey: .pressureSizeDefault)
        try c.encode(pressureOpacityDefault, forKey: .pressureOpacityDefault)
        try c.encode(forceTouchPressure, forKey: .forceTouchPressure)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(syncBrushAcrossTools, forKey: .syncBrushAcrossTools)
        // (kept only until they have been merged into the brush library)
        if !legacyFavoriteBrushes.isEmpty { try c.encode(legacyFavoriteBrushes, forKey: .favoriteBrushes) }
        if !legacyRecentBrushes.isEmpty { try c.encode(legacyRecentBrushes, forKey: .recentBrushes) }
    }
}

@Observable
final class TabletSettings {
    static let shared = TabletSettings()
    static let key = "ImageCrat.Tablet"
    /// Self tests and perf runs never read or write the user's defaults.
    static var isHeadless: Bool { ArtistSupport.isSelfTest }

    var prefs: TabletPrefs {
        didSet {
            guard prefs != oldValue else { return }
            if prefs.pressureSizeDefault != oldValue.pressureSizeDefault || prefs.pressureOpacityDefault != oldValue.pressureOpacityDefault {
                applyPressureDefaults()
            }
            guard !TabletSettings.isHeadless else { return }
            if let d = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(d, forKey: TabletSettings.key) }
        }
    }

    private init() {
        if !TabletSettings.isHeadless, let d = UserDefaults.standard.data(forKey: TabletSettings.key),
           let p = try? JSONDecoder().decode(TabletPrefs.self, from: d) {
            prefs = p
        } else {
            prefs = TabletPrefs()
        }
    }

    /// Sets the options-bar pressure buttons of every painting tool to the preference.
    func applyPressureDefaults() {
        let app = AppModel.shared
        for k in AppModel.brushTools {
            var s = app.brushSettings(for: k)
            s.pressureSize = prefs.pressureSizeDefault
            s.pressureOpacity = prefs.pressureOpacityDefault
            app.setBrushSettings(s, for: k)
        }
    }

    /// Called once at launch (not in self tests): the remembered defaults become the tools' starting state.
    func applyAtLaunch() {
        guard !TabletSettings.isHeadless else { return }
        applyPressureDefaults()
        migrateBrushLists(into: BrushLibrary.shared)
        TabletInput.shared.installMonitors()
    }

    // MARK: Quick picker lists (now the brush library's)

    /// Moves the favourites and recent brushes an earlier version kept here into the brush library, once: ids that are
    /// library brushes are merged, the rest dropped, and the old keys are not written again. Returns the ids taken over.
    @discardableResult
    func migrateBrushLists(into lib: BrushLibrary) -> Int {
        guard !prefs.legacyFavoriteBrushes.isEmpty || !prefs.legacyRecentBrushes.isEmpty else { return 0 }
        let n = lib.mergeLegacyLists(favorites: prefs.legacyFavoriteBrushes, recent: prefs.legacyRecentBrushes)
        prefs.legacyFavoriteBrushes = []
        prefs.legacyRecentBrushes = []
        return n
    }
}
