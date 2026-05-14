import XCTest
import UIKit
import Translation
@testable import OnscreenTranslator

@MainActor
final class TranslationPipelineTests: XCTestCase {
    func testRendersIMG4746() async throws {
        try await runPipeline(named: "IMG_4746")
    }

    func testRendersIMG4747() async throws {
        try await runPipeline(named: "IMG_4747")
    }

    /// Offline alignment test: OCR + fake translations + render. No network, no Apple Translation.
    /// Substitutes a long Chinese phrase for every non-target box to stress-test box expansion.
    /// Probe which Apple Translation language pairs are usable on the current
    /// host (simulator or device). Helpful for diagnosing why a real translation
    /// run is skipped.
    func testAppleLanguageAvailabilityProbe() async throws {
        guard #available(iOS 18.0, *) else { return }
        let availability = Translation.LanguageAvailability()
        let pairs: [(String, String)] = [
            ("th", "zh-Hans"),
            ("en", "zh-Hans"),
            ("zh-Hans", "en"),
            ("es", "en"),
            ("ja", "en"),
            ("fr", "en")
        ]
        var lines: [String] = []
        for (s, t) in pairs {
            let status = await availability.status(
                from: Locale.Language(identifier: s),
                to: Locale.Language(identifier: t)
            )
            lines.append("\(s) -> \(t): \(status)")
        }
        let report = lines.joined(separator: "\n")
        print("APPLE_AVAILABILITY:\n\(report)")
        let attachment = XCTAttachment(string: report)
        attachment.name = "apple-language-availability.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testRendererAlignmentOffline() async throws {
        try await runOfflineRender(named: "IMG_4747")
        try await runOfflineRender(named: "IMG_4746")
        try await runOfflineRender(named: "IMG_4780")
    }

    /// Real Apple Translation pipeline against IMG_4780. Requires the Thai→Chinese
    /// model to be installed on the simulator (Settings → General → Language &
    /// Region → Translation Languages, or first-time use will prompt to download).
    func testRealApplePipelineIMG4780() async throws {
        guard #available(iOS 18.0, *) else {
            throw XCTSkip("Apple Translation programmatic session requires iOS 18+")
        }
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "IMG_4780", withExtension: "PNG"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            XCTFail("Missing IMG_4780.PNG in test bundle")
            return
        }

        let ocrLanguages = ["th-TH", "zh-Hans", "en-US"]
        let understood = ["zh-Hans", "en"]

        let boxes = try await OCRService().recognizeText(in: image, languageHints: ocrLanguages)
        XCTAssertFalse(boxes.isEmpty, "OCR found no text")

        let texts = boxes.map(\.text)
        let toTranslate = LanguageDetector.indicesToTranslate(in: texts, understood: understood)
        let subset = toTranslate.map { texts[$0] }

        var translations = texts
        if !subset.isEmpty {
            let translated: [String]
            do {
                translated = try await AppleTranslationService().translate(
                    subset,
                    targetLanguageCode: "zh-Hans"
                )
            } catch {
                throw XCTSkip("Apple Translation unavailable in this simulator: \(error.localizedDescription)")
            }
            for (offset, originalIndex) in toTranslate.enumerated() where offset < translated.count {
                translations[originalIndex] = translated[offset]
            }
        }

        let rendered = try ScreenshotRenderer().render(
            source: image,
            boxes: boxes,
            translations: translations,
            maskOpacity: 0.88
        )

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outURL = docs.appendingPathComponent("IMG_4780-apple-rendered.png")
        try rendered.pngData()?.write(to: outURL)
        print("APPLE_RENDER_OUTPUT \(outURL.path)")

        let renderedAttachment = XCTAttachment(image: rendered)
        renderedAttachment.name = "IMG_4780-apple-rendered.png"
        renderedAttachment.lifetime = .keepAlways
        add(renderedAttachment)

        let diagnostics = zip(boxes, translations).enumerated().map { index, pair in
            let (box, translation) = pair
            let detected = LanguageDetector.detect(box.text) ?? "?"
            return "[\(index)] lang=\(detected) rect=\(box.rect) src=\"\(box.text)\" dst=\"\(translation)\""
        }.joined(separator: "\n")
        let diag = XCTAttachment(string: diagnostics)
        diag.name = "IMG_4780-apple-diagnostics.txt"
        diag.lifetime = .keepAlways
        add(diag)
    }

    private func runOfflineRender(named name: String) async throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: name, withExtension: "PNG"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            XCTFail("Missing \(name).PNG in test bundle")
            return
        }

        let ocrLanguages = ["th-TH", "zh-Hans", "en-US"]
        let understood = ["zh-Hans", "en"]

        let boxes = try await OCRService().recognizeText(in: image, languageHints: ocrLanguages)
        XCTAssertFalse(boxes.isEmpty, "OCR found no text in \(name)")

        let texts = boxes.map(\.text)
        let toTranslate = Set(LanguageDetector.indicesToTranslate(in: texts, understood: understood))
        // Mix of typical lengths so we exercise: short (fits in original box),
        // medium (wraps within ceiling), very long (forces ellipsis truncation).
        let fakes = [
            "提前预订",
            "享受额外优惠折扣",
            "立即查看最新促销活动并领取优惠券",
            "限时折扣",
            "节省高达50%"
        ]
        let translations: [String] = texts.enumerated().map { index, original in
            guard toTranslate.contains(index) else { return original }
            return fakes[index % fakes.count]
        }

        let rendered = try ScreenshotRenderer().render(
            source: image,
            boxes: boxes,
            translations: translations,
            maskOpacity: 0.88
        )

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outURL = docs.appendingPathComponent("\(name)-offline-rendered.png")
        try rendered.pngData()?.write(to: outURL)
        print("ALIGN_TEST_OUTPUT \(outURL.path)")

        let renderedAttachment = XCTAttachment(image: rendered)
        renderedAttachment.name = "\(name)-offline-rendered.png"
        renderedAttachment.lifetime = .keepAlways
        add(renderedAttachment)

        let diagnostics = zip(boxes, translations).enumerated().map { index, pair in
            let (box, translation) = pair
            let detected = LanguageDetector.detect(box.text) ?? "?"
            return "[\(index)] lang=\(detected) rect=\(box.rect) src=\"\(box.text)\" dst=\"\(translation)\""
        }.joined(separator: "\n")
        let diagAttachment = XCTAttachment(string: diagnostics)
        diagAttachment.name = "\(name)-offline-diagnostics.txt"
        diagAttachment.lifetime = .keepAlways
        add(diagAttachment)
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
            maskOpacity: defaults.maskOpacity,
            preferOnDeviceTranslation: false,
            understoodLanguages: defaults.understoodLanguages
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
