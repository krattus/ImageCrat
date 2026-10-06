// swift-tools-version:6.0
import PackageDescription

// The Mac app needs Apple-only frameworks and packages (MLX, CoreImage, AppKit…). On Windows and Linux this manifest
// declares only the portable core and its tests, so `swift build` / `swift test` work there from the same checkout.
// See docs/WINDOWS-PORT.md.

// Platform-independent core: document model, pixel storage and pure algorithms. Foundation + stdlib only, so it builds
// on Windows and Linux. Apple bridging (CoreGraphics/CoreImage/Metal/ImageIO) lives in the app as extensions
// (Sources/Lumen/CoreBridge). `scripts/check_core_portable.sh` enforces the import/API rules.
let core: Target = .target(
    name: "ImageCratCore",
    path: "Sources/ImageCratCore",
    swiftSettings: [.swiftLanguageMode(.v5)]
)

// Portable unit tests for the core (XCTest, no app, no GUI). They run on macOS and Windows.
let coreTests: Target = .testTarget(
    name: "ImageCratCoreTests",
    dependencies: ["ImageCratCore"],
    path: "Tests/ImageCratCoreTests",
    swiftSettings: [.swiftLanguageMode(.v5)]
)

#if os(macOS)
let package = Package(
    name: "Lumen",
    platforms: [.macOS(.v15)],
    dependencies: [
        // SAM 3.1 on MLX (text-prompt "High Quality" segmentation engine; pulls in mlx-swift).
        .package(url: "https://github.com/thesepehrm/sam31-swift", exact: "0.1.1"),
        // Content Credentials (C2PA) — Apache-2.0 / MIT
        .package(url: "https://github.com/contentauth/c2pa-swift.git", exact: "0.0.13"),
    ],
    targets: [
        core,
        // Web-export engine (Ultra PNG, optimal-parse deflate, JPEG encoder, quality metrics). Pure computation that is
        // hundreds of times slower without the optimiser, so it is always compiled with -O, also in debug builds.
        .target(
            name: "LumenUltra",
            path: "Sources/Lumen/WebExport/Engine",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-O", "-enable-testing"])]
        ),
        .executableTarget(
            name: "Lumen",
            dependencies: [
                .product(name: "SAM31", package: "sam31-swift"),
                .product(name: "C2PA", package: "c2pa-swift"),
                "LumenUltra",
                "ImageCratCore",
            ],
            path: "Sources/Lumen",
            exclude: ["WebExport/Engine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        coreTests,
    ]
)
#else
// Windows / Linux: the portable core and its tests, plus the Windows technical preview (docs/WINDOWS-PORT.md):
// - ImageCratWinSupport: portable support code for the preview (file loading, self-check, synthetic samples);
// - imagecrat-cli: console tool (portable: also builds on Linux);
// - ImageCratPreview: the Win32 GUI (Windows only, WinSDK).
// windows/build.ps1 links each executable with its own Windows resources (icon, manifest, version information).
var targets: [Target] = [
    core,
    coreTests,
    .target(
        name: "ImageCratWinSupport",
        dependencies: ["ImageCratCore"],
        path: "Sources/ImageCratWinSupport",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "ImageCratCLI",
        dependencies: ["ImageCratCore", "ImageCratWinSupport"],
        path: "Sources/ImageCratCLI",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
var products: [Product] = [.executable(name: "imagecrat-cli", targets: ["ImageCratCLI"])]

#if os(Windows)
targets.append(.executableTarget(
    name: "ImageCratPreview",
    dependencies: ["ImageCratCore", "ImageCratWinSupport"],
    path: "Sources/ImageCratPreview",
    swiftSettings: [.swiftLanguageMode(.v5)],
    linkerSettings: [
        // a GUI program (no console window) that still starts at Swift's main
        .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"]),
        .linkedLibrary("user32"), .linkedLibrary("gdi32"), .linkedLibrary("comctl32"), .linkedLibrary("comdlg32"), .linkedLibrary("shell32"),
    ]
))
products.append(.executable(name: "ImageCratPreview", targets: ["ImageCratPreview"]))
#endif

let package = Package(
    name: "ImageCrat",
    products: products,
    targets: targets
)
#endif
