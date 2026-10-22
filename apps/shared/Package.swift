// swift-tools-version:5.10
// Shared native UI for Linux and Windows, written once with SwiftCrossUI.
// Each platform app picks its native backend: GtkBackend (GTK 4) on Linux,
// WinUIBackend (WinUI 3) on Windows. `OrdalPreview` runs the same UI on macOS
// through AppKitBackend so it can be built and checked on a Mac.
import PackageDescription

let package = Package(
    name: "OrdalUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OrdalUI", targets: ["OrdalUI"]),
        .executable(name: "OrdalPreview", targets: ["OrdalPreview"]),
    ],
    dependencies: [
        .package(path: "../../swift"),
        .package(url: "https://github.com/moreSwift/swift-cross-ui", .upToNextMinor(from: "0.9.0")),
    ],
    targets: [
        .target(
            name: "OrdalUI",
            dependencies: [
                .product(name: "OrdalCore", package: "swift"),
                .product(name: "OrdalKit", package: "swift"),
                .product(name: "SwiftCrossUI", package: "swift-cross-ui"),
            ],
            path: "Sources/OrdalUI"
        ),
        .executableTarget(
            name: "OrdalPreview",
            dependencies: [
                "OrdalUI",
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            path: "Sources/OrdalPreview"
        ),
    ]
)
