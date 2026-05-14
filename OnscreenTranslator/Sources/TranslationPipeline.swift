import UIKit

struct TranslationPipeline: Sendable {
    private let ocr = OCRService()
    private let translator = TranslationService()
    private let renderer = ScreenshotRenderer()

    func process(image: UIImage, settings: AppSettings) async throws -> TranslationOutput {
        let boxes = try await ocr.recognizeText(in: image, languageHints: settings.ocrLanguages)
        guard !boxes.isEmpty else {
            throw TranslationError.noTextFound
        }

        let translated = try await translator.translate(
            boxes.map(\.text),
            targetLanguage: settings.targetLanguage,
            settings: settings
        )
        let output = try renderer.render(
            source: image,
            boxes: boxes,
            translations: translated,
            maskOpacity: settings.maskOpacity
        )

        return TranslationOutput(image: output, boxes: boxes, translations: translated, partialFailureNote: nil)
    }
}

struct TranslationOutput: Sendable {
    let image: UIImage
    let boxes: [RecognizedTextBox]
    let translations: [String]
    /// Non-nil when at least one translation likely failed (i.e. the rendered
    /// output still contains source-script text). Surfaced to the user as a
    /// non-fatal warning.
    let partialFailureNote: String?
}

/// Shared "filter → translate → splice" used by both the AppIntent and the
/// in-app manual flow. Keeps logic identical in both entry points.
enum BoxTranslator {
    /// Translates only the boxes whose detected language is not in the user's
    /// "understood" list. Returns the full translation list aligned with
    /// `boxes` AND a diagnostic note if more than 20% of the attempted boxes
    /// came back unchanged in the source script.
    @MainActor
    static func translate(
        boxes: [RecognizedTextBox],
        settings: AppSettings
    ) async throws -> (translations: [String], note: String?) {
        let texts = boxes.map(\.text)
        let understood = settings.understoodLanguages.isEmpty
            ? [settings.targetLanguageCode]
            : settings.understoodLanguages
        let toTranslate = LanguageDetector.indicesToTranslate(in: texts, understood: understood)
        guard !toTranslate.isEmpty else { return (texts, nil) }

        let subset = toTranslate.map { texts[$0] }
        let translated = try await translateSubset(subset, settings: settings)

        var output = texts
        var unchangedCount = 0
        for (offset, originalIndex) in toTranslate.enumerated() where offset < translated.count {
            output[originalIndex] = translated[offset]
            if translated[offset] == texts[originalIndex] { unchangedCount += 1 }
        }

        let attempted = toTranslate.count
        let unchangedRatio = attempted > 0 ? Double(unchangedCount) / Double(attempted) : 0
        let note: String?
        if attempted >= 5, unchangedRatio > 0.2 {
            note = "\(unchangedCount) of \(attempted) text regions could not be translated and were left in the original language."
        } else {
            note = nil
        }
        return (output, note)
    }

    @MainActor
    private static func translateSubset(_ texts: [String], settings: AppSettings) async throws -> [String] {
        if settings.preferOnDeviceTranslation, #available(iOS 18.0, *) {
            do {
                return try await AppleTranslationService().translate(
                    texts,
                    targetLanguageCode: settings.targetLanguageCode
                )
            } catch {
                // Fall through to cloud fallback. Apple Translation may fail when:
                // model not installed, user cancelled the download prompt, no active
                // window for hosting, or the language pair is unsupported.
            }
        }

        do {
            return try await TranslationService().translate(
                texts,
                targetLanguage: settings.targetLanguage,
                settings: settings
            )
        } catch TranslationError.missingAPIKey {
            throw TranslationError.requestFailed(
                "Add a Gemini (or other OpenAI-compatible) API key in Settings to use the Shortcut, or enable on-device translation with the language pair installed."
            )
        }
    }
}
