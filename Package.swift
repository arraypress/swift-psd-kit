// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "swift-psd-kit",
    // CoreGraphics, CoreText and Core Image for the pixels, ImageIO for the
    // payloads; nothing needs a window. macOS 26 for Core Image's typed
    // filter builders.
    platforms: [
        .macOS(.v26), .iOS(.v26)
    ],
    products: [
        .library(name: "PSDKit", targets: ["PSDKit"]),
    ],
    targets: [
        .target(name: "PSDKit"),
        .testTarget(name: "PSDKitTests", dependencies: ["PSDKit"],
                    resources: [.copy("Fixtures")]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
