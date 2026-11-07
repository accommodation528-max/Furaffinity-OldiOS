// swift-tools-version: 6.0
import PackageDescription

// FAPages —— FurAffinity 的**纯解析层**。
//
// 刻意做成独立包、零 UI / 零网络依赖：
//   * 可以在 Linux 上 `swift test`，不需要 Mac、不需要模拟器、不需要手机
//   * App 层改 UI 时这里不会被牵连
//
// 运行测试：cd FAPages && swift test
let package = Package(
    name: "FAPages",
    platforms: [
        .iOS(.v15),
        .macOS(.v11),
    ],
    products: [
        .library(name: "FAPages", targets: ["FAPages"]),
    ],
    dependencies: [
        // 本地 vendored：本机 git 到 github 会卡死，只有 HTTPS 可用
        .package(path: "../Vendor/SwiftSoup"),
    ],
    targets: [
        .target(
            name: "FAPages",
            dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")]
        ),
        .testTarget(
            name: "FAPagesTests",
            dependencies: ["FAPages"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
