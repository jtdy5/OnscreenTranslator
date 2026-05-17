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
        guard let workingCG = working.cgImage else {
            throw TranslationError.unreadableImage
        }
        let boxes = try await OCRService().recognizeText(in: workingCG, languageHints: settings.ocrLanguages)
        guard !boxes.isEmpty else {
            throw TranslationError.noTextFound
        }

        let result = try await BoxTranslator.translate(boxes: boxes, settings: settings)
        Self.writeDiagnosticDump(boxes: boxes, translations: result.translations, skipped: result.skipped)
        let renderedCG = try ScreenshotRenderer().render(
            source: workingCG,
            boxes: boxes,
            translations: result.translations,
            skippedIndices: result.skipped
        )
        let rendered = UIImage(cgImage: renderedCG, scale: working.scale, orientation: working.imageOrientation)
        return TranslationOutput(
            image: rendered,
            boxes: boxes,
            translations: result.translations,
            partialFailureNote: result.note
        )
    }

    /// Write the per-box OCR rect / source text / translation / skip flag to
    /// `Documents/last-ocr-diagnostic.txt`. The user can airdrop or share
    /// this file when debugging device-specific OCR / merge issues that
    /// can't be reproduced via the macOS render-preview CLI.
    private static func writeDiagnosticDump(
        boxes: [RecognizedTextBox],
        translations: [String],
        skipped: Set<Int>
    ) {
        var lines: [String] = []
        lines.append("# OCR diagnostic — \(Date())")
        lines.append("# columns: index | flag | rect(x,y,w,h) | source → translation")
        for (i, (box, t)) in zip(boxes, translations).enumerated() {
            let flag = skipped.contains(i) ? "skip" : "    "
            let r = String(format: "(%4.0f,%4.0f %4.0fx%4.0f)",
                           box.rect.minX, box.rect.minY, box.rect.width, box.rect.height)
            let srcEscaped = box.text.replacingOccurrences(of: "\n", with: "\\n")
            let dstEscaped = t.replacingOccurrences(of: "\n", with: "\\n")
            lines.append("[\(String(format: "%2d", i))] \(flag) \(r) \(srcEscaped) → \(dstEscaped)")
        }
        let payload = lines.joined(separator: "\n").data(using: .utf8) ?? Data()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let url = docs?.appendingPathComponent("last-ocr-diagnostic.txt") {
            try? payload.write(to: url, options: .atomic)
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
