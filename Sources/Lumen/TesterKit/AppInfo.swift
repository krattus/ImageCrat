import AppKit

/// Version, build and machine facts shown in About ImageCrat and in bug reports. Nothing here identifies the person:
/// no user name, computer name, serial number or hardware UUID.
enum AppInfo {
    /// `CFBundleShortVersionString` (set by scripts/build_app.sh from `VERSION`); "dev" for a `swift build` binary.
    static var version: String { info("CFBundleShortVersionString") ?? "dev" }
    /// `CFBundleVersion` (set by scripts/build_app.sh from `BUILD`).
    static var build: String { info("CFBundleVersion") ?? "development build" }
    static var versionLine: String { "Version \(version) (\(build))" }
    /// True when running from ImageCrat.app (not from a SwiftPM build folder).
    static var isAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private static func info(_ key: String) -> String? {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// e.g. "Mac15,8" (model identifier, not the serial number).
    static var modelIdentifier: String { sysctlString("hw.model") ?? "unknown" }
    /// e.g. "Apple M3 Max".
    static var chip: String { sysctlString("machdep.cpu.brand_string") ?? "unknown" }
    static var memoryGB: Int { Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded()) }
    /// e.g. "Version 15.6 (Build 24G84)".
    static var macOS: String { ProcessInfo.processInfo.operatingSystemVersionString }
    static var displays: [String] {
        NSScreen.screens.map { s in
            let f = s.frame
            return "\(Int(f.width))×\(Int(f.height)) pt @\(String(format: "%g", s.backingScaleFactor))x"
        }
    }
}
