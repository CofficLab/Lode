// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PluginChatEmptyState",
    defaultLocalization: "en",
    platforms: [.macOS("14.0")],
    products: [
        .library(name: "PluginChatEmptyState", targets: ["PluginChatEmptyState"])
    ],
    dependencies: [
        .package(url: "https://github.com/lumi-softworks/LumiKernel.git", from: "1.1.2"),
        .package(url: "https://github.com/lumi-softworks/LumiUI.git", from: "1.18.1"),
        .package(url: "https://github.com/lumi-softworks/LumiLocalization.git", from: "1.0.3"),
        .package(url: "https://github.com/lumi-softworks/LumiLogging.git", from: "1.0.3"),
        .package(url: "https://github.com/lumi-softworks/LumiProviders.git", from: "1.26.0"),
        .package(url: "https://github.com/lumi-softworks/LumiProviderMessage.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "PluginChatEmptyState",
            dependencies: [
                .product(name: "KernelCore", package: "LumiKernel"),
                .product(name: "LumiUI", package: "LumiUI"),
                .product(name: "LumiLocalizationKit", package: "LumiLocalization"),
                .product(name: "LumiLoggingKit", package: "LumiLogging"),
                .product(name: "ProviderChatSection", package: "LumiProviders"),
                .product(name: "ProviderConversation", package: "LumiProviders"),
                .product(name: "ProviderPromptSuggestion", package: "LumiProviders"),
                .product(name: "ProviderMessage", package: "LumiProviderMessage"),
            ],
            path: "Sources/PluginChatEmptyState",
            resources: [.process("../../Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "PluginChatEmptyStateTests",
            dependencies: [
                "PluginChatEmptyState",
                .product(name: "KernelCore", package: "LumiKernel"),
                .product(name: "ProviderChatSection", package: "LumiProviders"),
                .product(name: "ProviderConversation", package: "LumiProviders"),
                .product(name: "ProviderPromptSuggestion", package: "LumiProviders"),
                .product(name: "ProviderMessage", package: "LumiProviderMessage"),
            ],
            path: "Tests/PluginChatEmptyStateTests"
        ),
    ]
)