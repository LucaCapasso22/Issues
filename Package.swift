// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Issues",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Issues", targets: ["IssuesDesktop"])],
    targets: [
        .target(name: "IssuesCore"),
        .executableTarget(name: "IssuesDesktop", dependencies: ["IssuesCore"], resources: [.copy("Web")]),
        .testTarget(name: "IssuesCoreTests", dependencies: ["IssuesCore"])
    ]
)
