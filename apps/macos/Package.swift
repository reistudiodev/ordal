// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OrdalMac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../swift"),
    ],
    targets: [
        .executableTarget(
            name: "OrdalMac",
            dependencies: [
                .product(name: "OrdalCore", package: "swift"),
                .product(name: "OrdalKit", package: "swift"),
            ],
            path: "Sources/OrdalMac"
        ),
    ]
)
