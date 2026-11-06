// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MacCommandCore", platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "MacCommandCore", targets: ["MacCommandCore"])],
    targets: [.target(name: "MacCommandCore", path: "ios/MacCommand/Core"),
              .testTarget(name: "MacCommandCoreTests", dependencies: ["MacCommandCore"], path: "swift-tests/MacCommandCoreTests")])
