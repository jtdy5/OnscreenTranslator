// swift-tools-version:5.9
import PackageDescription

// macOS CLI tool for previewing OCR + translation rendering without going
// through Xcode/simulator. Reuses the iOS app's renderer and OCR sources by
// listing them explicitly; the xcodeproj-based iOS build is unaffected.
let package = Package(
    name: "render-preview",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "render-preview",
            path: ".",
            exclude: [
                "README.md",
                "project.yml",
                "OnscreenTranslator.xcodeproj",
                "OnscreenTranslator/Sources/ContentView.swift",
                "OnscreenTranslator/Sources/AppIntents.swift",
                "OnscreenTranslator/Sources/AppleTranslationService.swift",
                "OnscreenTranslator/Sources/AppleTranslationCoordinator.swift",
                "OnscreenTranslator/Sources/ImageScaler.swift",
                "OnscreenTranslator/Sources/OnscreenTranslatorApp.swift",
                "OnscreenTranslator/Sources/TranslationHistory.swift",
                "OnscreenTranslator/Sources/TranslationPipeline.swift",
                "OnscreenTranslator/Resources",
                "OnscreenTranslator/Tests",
                "source-images-examples"
            ],
            sources: [
                "OnscreenTranslator/Sources/Models.swift",
                "OnscreenTranslator/Sources/OCRService.swift",
                "OnscreenTranslator/Sources/ScreenshotRenderer.swift",
                "OnscreenTranslator/Sources/LanguageDetector.swift",
                "OnscreenTranslator/Sources/SupportedLanguage.swift",
                "OnscreenTranslator/Sources/SettingsStore.swift",
                "OnscreenTranslator/Sources/KeychainStore.swift",
                "OnscreenTranslator/Sources/TranslationService.swift",
                "Tools/RenderPreview/RenderPreview.swift"
            ]
        )
    ]
)
