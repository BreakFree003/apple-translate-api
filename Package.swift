// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apple-translate-api",
    platforms: [
        // 只走 macOS 26+ 的直连路径（TranslationSession(installedSource:target:)）。
        // macOS 15–25 只能靠 SwiftUI 的 .translationTask + 隐形窗口，本工程不覆盖。
        .macOS("26.0")
    ],
    products: [
        .executable(name: "apple-translate-server", targets: ["AppleTranslateServer"])
    ],
    targets: [
        .executableTarget(
            name: "AppleTranslateServer",
            path: "Sources/AppleTranslateServer"
        ),
        // 只测纯逻辑（HTTP 解析、prompt 切分、语言目录、配置）。
        // 真正的翻译依赖本机装了哪些语言包，进不了单测 —— 那些归 scripts/e2e.sh。
        .testTarget(
            name: "AppleTranslateServerTests",
            dependencies: ["AppleTranslateServer"],
            path: "Tests/AppleTranslateServerTests"
        )
    ]
)
