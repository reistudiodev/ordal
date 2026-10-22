// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OrdalWindows",
    dependencies: [
        .package(path: "../../swift"),
    ],
    targets: [
        .executableTarget(
            name: "OrdalWindows",
            dependencies: [.product(name: "OrdalCore", package: "swift")],
            path: "Sources/OrdalWindows"
        ),
    ]
)
