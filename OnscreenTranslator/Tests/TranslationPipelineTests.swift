import XCTest
import UIKit
@testable import OnscreenTranslator

@MainActor
final class TranslationPipelineTests: XCTestCase {
    func testRendersIMG4746() async throws {
        try await runPipeline(named: "IMG_4746")
    }

    func testRendersIMG4747() async throws {
        try await runPipeline(named: "IMG_4747")
    }

    private func runPipeline(named name: String) async throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "PNG"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            XCTFail("Missing \(name).PNG in test bundle")
            return
        }

        let defaults = AppSettings.fromDefaults()
        let settings = AppSettings(
            targetLanguage: ProcessInfo.processInfo.environment["TEST_TARGET_LANGUAGE"] ?? "Chinese",
            targetLanguageCode: ProcessInfo.processInfo.environment["TEST_TARGET_CODE"] ?? "zh-Hans",
            endpoint: defaults.endpoint,
            model: ProcessInfo.processInfo.environment["TEST_MODEL"] ?? "gemini-2.5-flash",
            ocrLanguages: defaults.ocrLanguages,
            apiKey: defaults.apiKey,
            maskOpacity: defaults.maskOpacity
        )
        XCTAssertFalse(
            settings.apiKey.isEmpty,
            "GEMINI_API_KEY missing — check Secrets.xcconfig and host app Info.plist"
        )

        let boxes = try await OCRService().recognizeText(
            in: image,
            languageHints: settings.ocrLanguages
        )
        XCTAssertFalse(boxes.isEmpty, "OCR found no text in \(name)")

        let translations = try await TranslationService().translate(
            boxes.map(\.text),
            targetLanguage: settings.targetLanguage,
            settings: settings
        )
        XCTAssertEqual(translations.count, boxes.count, "Translation count mismatch")

        let rendered = try ScreenshotRenderer().render(
            source: image,
            boxes: boxes,
            translations: translations,
            maskOpacity: settings.maskOpacity
        )

        let renderedAttachment = XCTAttachment(image: rendered)
        renderedAttachment.name = "\(name)-rendered.png"
        renderedAttachment.lifetime = .keepAlways
        add(renderedAttachment)

        let sourceAttachment = XCTAttachment(image: image)
        sourceAttachment.name = "\(name)-source.png"
        sourceAttachment.lifetime = .keepAlways
        add(sourceAttachment)

        let diagnostics = zip(boxes, translations).enumerated().map { index, pair in
            let (box, translation) = pair
            return "[\(index)] rect=\(box.rect) src=\"\(box.text)\" dst=\"\(translation)\""
        }.joined(separator: "\n")
        let diagAttachment = XCTAttachment(string: diagnostics)
        diagAttachment.name = "\(name)-diagnostics.txt"
        diagAttachment.lifetime = .keepAlways
        add(diagAttachment)
    }
}
