// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReviewDesk",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ReviewDeskCore"),
        .executableTarget(name: "ReviewDesk", dependencies: ["ReviewDeskCore"]),
        .testTarget(name: "ReviewDeskCoreTests", dependencies: ["ReviewDeskCore"]),
    ]
)
