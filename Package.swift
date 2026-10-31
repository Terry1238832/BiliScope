// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BiliScope",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BiliScopeCore", targets: ["BiliScopeCore"]),
        .executable(name: "biliscope-proxy", targets: ["biliscope-proxy"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
    ],
    targets: [
        .target(
            name: "BiliScopeCore",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .executableTarget(
            name: "biliscope-proxy",
            dependencies: ["BiliScopeCore"]
        ),
        .testTarget(
            name: "BiliScopeCoreTests",
            dependencies: ["BiliScopeCore"]
        ),
    ]
)
