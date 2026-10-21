// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DBClientWindows",
    dependencies: [
        .package(path: "../../swift"),
    ],
    targets: [
        .executableTarget(
            name: "DBClientWindows",
            dependencies: [.product(name: "DBClientCore", package: "swift")],
            path: "Sources/DBClientWindows"
        ),
    ]
)
