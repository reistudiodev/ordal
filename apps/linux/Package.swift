// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DBClientLinux",
    dependencies: [
        .package(path: "../../swift"),
    ],
    targets: [
        .executableTarget(
            name: "DBClientLinux",
            dependencies: [.product(name: "DBClientCore", package: "swift")],
            path: "Sources/DBClientLinux"
        ),
    ]
)
