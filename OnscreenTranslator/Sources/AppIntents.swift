import AppIntents
import UIKit
import UniformTypeIdentifiers

struct TranslateCurrentScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Translate Current Screenshot"
    static let description = IntentDescription("Recognize text in a screenshot, translate it, and return a translated PNG.")
    static let openAppWhenRun = false

    @Parameter(title: "Screenshot", description: "The image to translate.")
    var screenshot: IntentFile

    @Parameter(title: "Target Language", description: "Override the app's default target language. Leave blank to use Settings.")
    var targetLanguage: String?

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> & ProvidesDialog {
        guard let image = UIImage(data: screenshot.data) else {
            throw TranslationError.unreadableImage
        }

        var settings = AppSettings.fromDefaults()
        if let override = targetLanguage?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            settings = AppSettings(
                targetLanguage: override,
                targetLanguageCode: settings.targetLanguageCode,
                endpoint: settings.endpoint,
                model: settings.model,
                ocrLanguages: settings.ocrLanguages,
                apiKey: settings.apiKey,
                maskOpacity: settings.maskOpacity
            )
        }

        let output = try await processShortcutImage(image, settings: settings)
        guard let data = output.image.pngData() else {
            throw TranslationError.unreadableImage
        }

        let file = IntentFile(data: data, filename: "translated-screenshot.png", type: .png)
        return .result(
            value: file,
            dialog: "Translated \(output.boxes.count) text regions to \(settings.targetLanguage)."
        )
    }

    private func processShortcutImage(_ image: UIImage, settings: AppSettings) async throws -> TranslationOutput {
        let working = ImageScaler.downscale(image)
        let boxes = try await OCRService().recognizeText(in: working, languageHints: settings.ocrLanguages)
        guard !boxes.isEmpty else {
            throw TranslationError.noTextFound
        }

        do {
            let translations = try await TranslationService().translate(
                boxes.map(\.text),
                targetLanguage: settings.targetLanguage,
                settings: settings
            )
            let rendered = try ScreenshotRenderer().render(
                source: working,
                boxes: boxes,
                translations: translations,
                maskOpacity: settings.maskOpacity
            )
            return TranslationOutput(image: rendered, boxes: boxes, translations: translations)
        } catch TranslationError.missingAPIKey {
            throw TranslationError.requestFailed(
                "Add a Gemini (or other OpenAI-compatible) API key in Settings to use the Shortcut."
            )
        }
    }
}

struct OnscreenTranslatorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TranslateCurrentScreenshotIntent(),
            phrases: [
                "Translate current screenshot with \(.applicationName)",
                "Translate screen with \(.applicationName)"
            ],
            shortTitle: "Translate Screenshot",
            systemImageName: "text.viewfinder"
        )
    }
}
