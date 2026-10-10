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
        )
    ]
)
