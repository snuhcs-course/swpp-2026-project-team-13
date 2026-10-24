// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SORICore", platforms: [.macOS(.v13), .iOS(.v17)], products: [.library(name: "SORICore", targets: ["SORICore"])], targets: [.target(name: "SORICore", path: "IPadApp/IPadApp/Core"), .testTarget(name: "SORICoreTests", dependencies: ["SORICore"], path: "Tests/SORICoreTests")])
