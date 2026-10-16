// swift-tools-version: 5.9
//
//  KebiaoCore —— 纯逻辑层（无 UIKit / 无 SwiftUI / 无 WidgetKit 依赖）。
//
//  这样分层的原因：课程表算法、周次判断、配色、数据模型都必须能用 `swift test` 在
//  macOS 上直接跑单测，而不必先起模拟器或真机。Android 端这些逻辑散落在
//  Compose 源码里、只能靠读代码推断；iOS 端把它们提出来，是可测试的。
//
//  验证方式（在 macOS 上）：
//      cd KebiaoCore && swift test
//  或直接让 CI 跑（本机是 Windows，没有 Swift 工具链）：
//      .github/workflows/ios-build.yml 的 `core-tests` job

import PackageDescription

let package = Package(
    name: "KebiaoCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "KebiaoCore", targets: ["KebiaoCore"])
    ],
    targets: [
        .target(
            name: "KebiaoCore",
            path: "Sources/KebiaoCore"
        ),
        .testTarget(
            name: "KebiaoCoreTests",
            dependencies: ["KebiaoCore"],
            path: "Tests/KebiaoCoreTests"
        )
    ]
)
