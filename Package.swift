// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Listo",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ListoEngine", targets: ["ListoEngine"]),
        .executable(name: "ListoApp", targets: ["ListoApp"]),
    ],
    targets: [
        .target(
            name: "ListoEngine",
            path: "Sources/ListoEngine"
        ),
        .executableTarget(
            name: "ListoApp",
            dependencies: ["ListoEngine"],
            path: "Sources/ListoApp",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ListoEngineTests",
            dependencies: ["ListoEngine"],
            path: "Tests/ListoEngineTests"
        ),
    ]
)
