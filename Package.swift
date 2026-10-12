// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReviewDesk",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ReviewDeskCore"),
        .testTarget(name: "ReviewDeskCoreTests", dependencies: ["ReviewDeskCore"]),
    ]
)
