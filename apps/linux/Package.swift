// swift-tools-version:5.10
// Native Linux Desktop App using GTK 4 (via GtkBackend in SwiftCrossUI).
import PackageDescription

let package = Package(
    name: "OrdalLinux",
    dependencies: [
        .package(path: "../../swift"),
        .package(path: "../shared"),
        .package(url: "https://github.com/moreSwift/swift-cross-ui", .upToNextMinor(from: "0.9.0")),
    ],
    targets: [
        .executableTarget(
            name: "OrdalLinux",
            dependencies: [
                .product(name: "OrdalCore", package: "swift"),
                .product(name: "OrdalKit", package: "swift"),
                .product(name: "OrdalUI", package: "shared"),
                .product(name: "DefaultBackend", package: "swift-cross-ui"),
            ],
            path: "Sources/OrdalLinux"
        ),
    ]
)
