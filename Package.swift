// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DisplayPanel",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "dp", targets: ["dp"]),
        .executable(name: "DisplayPanelApp", targets: ["DisplayPanelApp"])
    ],
    targets: [
        .target(name: "DisplayPanelCore"),
        .executableTarget(name: "dp", dependencies: ["DisplayPanelCore"]),
        .executableTarget(name: "DisplayPanelApp", dependencies: ["DisplayPanelCore"]),
        .testTarget(name: "DisplayPanelCoreTests", dependencies: ["DisplayPanelCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "DisplayPanelAppTests", dependencies: ["DisplayPanelApp", "DisplayPanelCore"])
    ]
)
