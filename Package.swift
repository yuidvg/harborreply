// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborReply",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HarborCore", targets: ["HarborCore"]), .executable(name: "HarborReply", targets: ["HarborReply"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "MailStoreReadOnly"),
        .executableTarget(name: "HarborMailReader", dependencies: ["MailStoreReadOnly"]),
        .testTarget(name: "MailStoreReadOnlyTests", dependencies: ["MailStoreReadOnly"]),
        .target(name: "HarborCore"),
        .executableTarget(name: "HarborReply", dependencies: ["HarborCore", .product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources")]),
        .testTarget(name: "HarborCoreTests", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborReplyTests", dependencies: ["HarborReply", "HarborCore"])
    ],
    swiftLanguageModes: [.v5]
)
