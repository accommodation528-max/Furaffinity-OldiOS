// swift-tools-version: 6.0
import PackageDescription

// FAIOS —— FurAffinity 第三方客户端（iOS 15+，SwiftUI）
//
// 构建：xtool dev build --ipa        （WSL / Linux，无需 Mac）
// 真机：TrollStore 安装签名无关的 ipa
//
// 注意：swift-tools-version 故意停在 6.0，不启用 Swift 6 严格并发，
// 以便和 SwiftSoup 这类老库共存。别改成 6.4。
let package = Package(
    name: "FAIOS",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        // xtool 要求：恰好一个 library product，代表主 App
        .library(name: "FAIOS", targets: ["FAIOS"]),
    ],
    dependencies: [
        .package(path: "../FAPages"),
    ],
    targets: [
        .target(
            name: "FAIOS",
            dependencies: [
                .product(name: "FAPages", package: "FAPages"),
            ]
        ),
    ],
    // swift-tools-version 6.0 默认就是 Swift 6 语言模式（严格并发），
    // 这里显式退回 Swift 5 —— 否则每个 ViewModel/singleton 都要为 Sendable 打架，
    // 拖慢 M1–M4 的 UI 开发。等主体稳定后再单独收紧。
    swiftLanguageModes: [.v5]
)
