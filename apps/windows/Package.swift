// swift-tools-version:5.10
// Native Windows Desktop App using WinUI 3 / Win32 (via WinUIBackend in SwiftCrossUI).
import PackageDescription

let package = Package(
    name: "OrdalWindows",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../swift"),
        .package(path: "../shared"),
        .package(url: "https://github.com/moreSwift/swift-cross-ui", .upToNextMinor(from: "0.9.0")),
    ],
    targets: [
        .executableTarget(
            name: "OrdalWindows",
            dependencies: [
                .product(name: "OrdalCore", package: "swift"),
                .product(name: "OrdalKit", package: "swift"),
                .product(name: "OrdalUI", package: "shared"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            path: "Sources/OrdalWindows"
        ),
    ]
)
