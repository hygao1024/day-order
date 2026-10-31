// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DayOrder",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DayOrder", targets: ["DayOrder"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "DayOrderCore", resources: [.process("Resources")]),
        .executableTarget(name: "DayOrder", dependencies: ["DayOrderCore", .product(name: "Sparkle", package: "Sparkle")],
                         linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "DayOrderCoreTests", dependencies: ["DayOrderCore"])
    ]
)
