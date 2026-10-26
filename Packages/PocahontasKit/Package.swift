// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "PocahontasKit",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "PocahontasKit", targets: ["PocahontasKit"])],
  dependencies: [
    .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.12.1"),
    .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", exact: "0.3.4"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
  ],
  targets: [
    .target(
      name: "PocahontasKit",
      dependencies: [
        .product(name: "Citadel", package: "Citadel"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "Crypto", package: "swift-crypto"),
      ]),
    .testTarget(
      name: "PocahontasKitTests",
      dependencies: [
        "PocahontasKit", .product(name: "NIOEmbedded", package: "swift-nio"),
      ], resources: [.copy("Fixtures")]),
  ]
)
