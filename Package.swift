// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DayOrder",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DayOrder", targets: ["DayOrder"])],
    targets: [
        .target(name: "DayOrderCore", resources: [.process("Resources")]),
        .executableTarget(name: "DayOrder", dependencies: ["DayOrderCore"]),
        .testTarget(name: "DayOrderCoreTests", dependencies: ["DayOrderCore"])
    ]
)
