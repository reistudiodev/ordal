// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DBClientMac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../swift"),
    ],
    targets: [
        .executableTarget(
            name: "DBClientMac",
            dependencies: [
                .product(name: "DBClientCore", package: "swift"),
                .product(name: "DBClientKit", package: "swift"),
            ],
            path: "Sources/DBClientMac"
        ),
    ]
)
