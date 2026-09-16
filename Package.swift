// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Listo",
    platforms: [.macOS(.v14)], // .onKeyPress (Tab/Shift+Tab for indent/outdent) needs macOS 14+
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
            // AppIcon.icns is packaged into the .app bundle by Scripts/release.sh,
            // not needed by `swift build`/`swift run` themselves.
            exclude: ["Resources/AppIcon.icns"]
        ),
        .testTarget(
            name: "ListoEngineTests",
            dependencies: ["ListoEngine"],
            path: "Tests/ListoEngineTests"
        ),
    ]
)
