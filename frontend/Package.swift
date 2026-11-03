// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "SolfegeCore", platforms: [.macOS(.v13), .iOS(.v17)], products: [.library(name: "SolfegeCore", targets: ["SolfegeCore"])], targets: [.target(name: "SolfegeCore", path: "IPadApp/IPadApp/Core"), .testTarget(name: "SolfegeCoreTests", dependencies: ["SolfegeCore"], path: "Tests/SolfegeCoreTests")])
