// swift-tools-version:6.0
import PackageDescription

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
        // Platform-independent core: document model, pixel storage and pure algorithms. Foundation + stdlib only, so it
        // can build on Windows and Linux later. Apple bridging (CoreGraphics/CoreImage/Metal/ImageIO) lives in the app as
        // extensions (Sources/Lumen/CoreBridge). `scripts/check_core_portable.sh` enforces the import/API rules.
        .target(
            name: "ImageCratCore",
            path: "Sources/ImageCratCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
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
        // Portable unit tests for the core (XCTest, no app, no GUI). The first tests that will also run on Windows/Linux.
        .testTarget(
            name: "ImageCratCoreTests",
            dependencies: ["ImageCratCore"],
            path: "Tests/ImageCratCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
