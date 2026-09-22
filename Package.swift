// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PallerKeyboard",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PallerKeyboard", targets: ["PallerKeyboard"])
    ],
    targets: [
        .executableTarget(name: "PallerKeyboard")
    ],
    swiftLanguageModes: [.v5]
)
