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

        return TranslationOutput(image: output, boxes: boxes, translations: translated)
    }
}

struct TranslationOutput: Sendable {
    let image: UIImage
    let boxes: [RecognizedTextBox]
    let translations: [String]
}
