import Foundation
import ObjectiveC

/// SAM 3.1's CLIP tokenizer files (`clip-vocab.json`, `clip-merges.txt`) ship in SwiftPM's resource bundle
/// `sam31-swift_SAM31.bundle`. The package reads them through its generated `Bundle.module` accessor, which tries
/// `<Lumen.app>/sam31-swift_SAM31.bundle` (the app's root folder, where a signed app can't have files) and then the
/// absolute build folder baked in at compile time (it only exists on the Mac that built Lumen); it has no API or
/// environment variable for another location, and its tokenizer type is internal.
///
/// So scripts/build_app.sh copies the bundle into `Lumen.app/Contents/Resources`, and before SAM 3.1 is first used
/// `installLookup()` makes `Bundle(path:)` answer a request for a *missing* `…/sam31-swift_SAM31.bundle` with the copy
/// Lumen found (`bundleURL`). Only that exact bundle name is affected, only when the requested path doesn't exist, and
/// a development binary (whose build folder has the bundle next to the executable) never needs it.
enum SAM3Resources {
    static let bundleName = "sam31-swift_SAM31.bundle"
    /// Paths inside the bundle the package opens (`Bundle.module.url(forResource: "Resources/clip-vocab", withExtension: "json")`).
    static let requiredFiles = ["Resources/clip-vocab.json", "Resources/clip-merges.txt"]

    /// Where Lumen looks, in order: the app's `Contents/Resources`, next to the executable (a SwiftPM build folder),
    /// and the bundle root (where the package's own accessor looks first).
    static func candidates(bundleURL: URL = Bundle.main.bundleURL, resourceURL: URL? = Bundle.main.resourceURL,
                           executableDir: URL? = Bundle.main.executableURL?.deletingLastPathComponent()) -> [URL] {
        var out: [URL] = []
        for base in [resourceURL, executableDir, bundleURL].compactMap({ $0 }) {
            let u = base.appendingPathComponent(bundleName)
            if !out.contains(u) { out.append(u) }
        }
        return out
    }

    static func isComplete(_ bundle: URL) -> Bool {
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: bundle.appendingPathComponent($0).path) }
    }

    static func locate(_ candidates: [URL]) -> URL? { candidates.first(where: isComplete) }

    /// The tokenizer bundle this copy of Lumen will use, or nil when it's missing.
    static var bundleURL: URL? { locate(candidates()) }

    // MARK: Lookup redirect

    private static let lock = NSLock()
    nonisolated(unsafe) private static var target: URL?
    nonisolated(unsafe) private static var installed = false

    /// The path `Bundle(path:)` opens instead of `path`: the found bundle, when `path` names a missing tokenizer bundle.
    static func redirectedPath(for path: String) -> String? {
        guard (path as NSString).lastPathComponent == bundleName else { return nil }
        lock.lock(); let t = target; lock.unlock()
        guard let t, t.path != path, !FileManager.default.fileExists(atPath: path) else { return nil }
        return t.path
    }

    /// Points the package's resource lookup at `bundle` (default: the one found in this copy of Lumen). Safe to call
    /// repeatedly; the hook is installed once per process. Returns false when there is nothing to point at.
    @discardableResult
    static func installLookup(_ bundle: URL? = SAM3Resources.bundleURL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        target = bundle
        guard bundle != nil else { return false }
        if installed { return true }
        let sel = NSSelectorFromString("initWithPath:")
        guard let m = class_getInstanceMethod(Bundle.self, sel) else { return false }
        typealias Init = @convention(c) (UnsafeRawPointer, Selector, NSString) -> UnsafeRawPointer?
        let original = unsafeBitCast(method_getImplementation(m), to: Init.self)
        // `self` and the result are passed through untouched (raw pointers): ownership stays exactly as the caller and
        // the original initializer expect.
        let replacement: @convention(block) (UnsafeRawPointer, NSString) -> UnsafeRawPointer? = { me, path in
            if let p = SAM3Resources.redirectedPath(for: path as String) { return original(me, sel, p as NSString) }
            return original(me, sel, path)
        }
        method_setImplementation(m, imp_implementationWithBlock(replacement))
        installed = true
        return true
    }

    static var lookupInstalled: Bool { lock.lock(); defer { lock.unlock() }; return installed && target != nil }
}
