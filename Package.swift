// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeySwitcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "KeySwitcher", targets: ["KeySwitcher"]),
        .executable(name: "KeySwitcherTestRunner", targets: ["KeySwitcherTestRunner"]),
        .library(name: "KeySwitcherCore", targets: ["KeySwitcherCore"])
    ],
    targets: [
        .target(
            name: "KeySwitcherCore",
            path: "Sources/KeySwitcherCore"
        ),
        .executableTarget(
            name: "KeySwitcher",
            dependencies: ["KeySwitcherCore"],
            path: "Sources/KeySwitcher"
        ),
        .executableTarget(
            name: "KeySwitcherTestRunner",
            dependencies: ["KeySwitcherCore"],
            path: "Sources/KeySwitcherTestRunner"
        ),
        .testTarget(
            name: "KeySwitcherTests",
            dependencies: ["KeySwitcherCore"],
            path: "Tests/KeySwitcherTests"
        )
    ]
)
