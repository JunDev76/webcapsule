// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WebCapsuleCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "WebCapsuleCore", targets: ["WebCapsuleCore"])],
    targets: [
        .target(name: "WebCapsuleCore"),
        .testTarget(name: "WebCapsuleCoreTests", dependencies: ["WebCapsuleCore"]),
    ]
)
