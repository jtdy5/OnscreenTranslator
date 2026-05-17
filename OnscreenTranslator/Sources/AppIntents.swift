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
                preferOnDeviceTranslation: settings.preferOnDeviceTranslation,
                understoodLanguages: settings.understoodLanguages
            )
        }

        let output = try await processShortcutImage(image, settings: settings)
        guard let data = output.image.pngData() else {
            throw TranslationError.unreadableImage
        }

        let file = IntentFile(data: data, filename: "translated-screenshot.png", type: .png)
        var dialog = "Translated \(output.boxes.count) text regions to \(settings.targetLanguage)."
        if let note = output.partialFailureNote {
            dialog += " " + note
        }
        return .result(
            value: file,
            dialog: IntentDialog(stringLiteral: dialog)
        )
    }

    private func processShortcutImage(_ image: UIImage, settings: AppSettings) async throws -> TranslationOutput {
        let working = ImageScaler.downscale(image)
        let boxes = try await OCRService().recognizeText(in: working, languageHints: settings.ocrLanguages)
        guard !boxes.isEmpty else {
            throw TranslationError.noTextFound
        }

        let result = try await BoxTranslator.translate(boxes: boxes, settings: settings)
        let rendered = try ScreenshotRenderer().render(
            source: working,
            boxes: boxes,
            translations: result.translations,
            skippedIndices: result.skipped
        )
        return TranslationOutput(
            image: rendered,
            boxes: boxes,
            translations: result.translations,
            partialFailureNote: result.note
        )
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
