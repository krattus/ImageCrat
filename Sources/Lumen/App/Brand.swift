import Foundation
import UniformTypeIdentifiers

/// The product's identity: everything a user, tester or the system sees. The SwiftPM target / module, the source folder,
/// the `LUMEN_*` test environment variables and internal UserDefaults keys (`Lumen.Workspace`, …) keep the old internal
/// name; they are never shown. `Legacy` is what the app was called before (files, folders and settings still read).
enum Brand {
    static let name = "ImageCrat"
    static let bundleIdentifier = "app.imagecrat.editor"
    /// `CFBundleExecutable`: crash reports are `ImageCrat-<date>.ips`.
    static let executableName = "ImageCrat"
    /// `~/Library/Application Support/ImageCrat`.
    static let supportFolderName = "ImageCrat"
    static let keychainService = "app.imagecrat.editor.apikeys"

    // Native document
    static let documentExtension = "imagecrat"
    static let documentTypeIdentifier = "app.imagecrat.document"
    static let documentTypeName = "ImageCrat Document"
    /// Bundle resource (Contents/Resources/ImageCratDocument.icns) registered as the document icon.
    static let documentIconName = "ImageCratDocument"

    // Other files the app writes (the old `.lumen…` forms are still accepted when opening / importing)
    static let recipeExtension = "icrecipe"
    static let libraryExtension = "iclib"
    static let actionsExtension = "icactions"

    /// What the app was called before the rename. Only read (migration, legacy files), never shown as the app's name.
    enum Legacy {
        static let name = "Lumen"
        static let bundleIdentifier = "app.lumen.editor"
        static let executableName = "Lumen"
        static let supportFolderName = "Lumen"
        static let keychainService = "app.lumen.editor.apikeys"
        static let documentExtension = "lumen"
        static let documentTypeIdentifier = "app.lumen.document"
        static let recipeExtension = "lumenrecipe"
        static let libraryExtension = "lumenlib"
        static let actionsExtension = "lumenactions"
    }

    /// Native document extensions the app opens (and saves in place): `.imagecrat`, and `.lumen` from before the rename.
    static let nativeExtensions: Set<String> = [documentExtension, Legacy.documentExtension]
    static func isNativeDocument(_ url: URL) -> Bool { nativeExtensions.contains(url.pathExtension.lowercased()) }
    static let recipeExtensions: Set<String> = [recipeExtension, Legacy.recipeExtension]
    static let libraryExtensions: Set<String> = [libraryExtension, Legacy.libraryExtension]
    static let actionsExtensions: Set<String> = [actionsExtension, Legacy.actionsExtension]

    /// `app.imagecrat.document` (declared in Info.plist by scripts/build_app.sh); a dynamic type for the extension in a
    /// bare `swift build` binary, which has no Info.plist.
    static var documentType: UTType { UTType(documentTypeIdentifier) ?? UTType(filenameExtension: documentExtension) ?? .data }
    /// `app.lumen.document` (imported in Info.plist) for `.lumen` files.
    static var legacyDocumentType: UTType { UTType(Legacy.documentTypeIdentifier) ?? UTType(filenameExtension: Legacy.documentExtension) ?? .data }

    /// `~/Library/Application Support/ImageCrat`, or `$LUMEN_SUPPORT_DIR`. Automated runs (self tests, fuzzing, scripts)
    /// without an override get a private temporary folder: they must never write into the user's real one (on
    /// 2026-10-03 test files there turned the first-launch migration from a rename into a merge).
    static var supportFolder: URL {
        if let o = ProcessInfo.processInfo.environment["LUMEN_SUPPORT_DIR"], !o.isEmpty { return URL(fileURLWithPath: o, isDirectory: true) }
        if GenAIKeyOverrides.realKeysBlocked { return automatedSupportFolder }
        return realSupportFolder
    }
    /// The user's real folder, whatever the process.
    static var realSupportFolder: URL { applicationSupport.appendingPathComponent(supportFolderName, isDirectory: true) }
    static let automatedSupportFolder: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ImageCrat-automated-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }
}
