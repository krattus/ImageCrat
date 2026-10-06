import Foundation

/// Version, build stamp and licence text shown by About and `--version`.
package enum BuildInfo {
    package static let productName = "ImageCrat Preview"
    package static let version = "0.1.0"
    /// Set by windows/build.ps1 (BuildStamp.swift); "development build" otherwise.
    package static let buildDate = BuildStamp.date ?? "development build"
    package static let licence = "Free for non-commercial use — PolyForm Noncommercial 1.0.0"
    package static let website = "https://github.com/krattus/ImageCrat"
    package static let copyright = "© 2026 krattus"

    package static var architecture: String {
        #if arch(x86_64)
        return "x64"
        #elseif arch(arm64)
        return "arm64"
        #else
        return "unknown architecture"
        #endif
    }

    package static var platformDescription: String {
        #if os(Windows)
        return "Windows \(architecture)"
        #elseif os(macOS)
        return "macOS \(architecture)"
        #else
        return "\(architecture)"
        #endif
    }

    package static var versionLine: String { "\(productName) \(version) (technical preview, \(platformDescription), built \(buildDate))" }
}
