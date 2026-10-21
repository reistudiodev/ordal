// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DBClientMac",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../swift"),
    ],
    targets: [
        .executableTarget(
            name: "DBClientMac",
            dependencies: [.product(name: "DBClientCore", package: "swift")],
            path: "Sources/DBClientMac"
        ),
    ]
)
