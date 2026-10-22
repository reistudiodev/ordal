// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OrdalLinux",
    dependencies: [
        .package(path: "../../swift"),
    ],
    targets: [
        .executableTarget(
            name: "OrdalLinux",
            dependencies: [.product(name: "OrdalCore", package: "swift")],
            path: "Sources/OrdalLinux"
        ),
    ]
)
