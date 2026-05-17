import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// macOS CLI that mirrors the iOS pipeline: load image → Vision OCR →
// cloud translation → ScreenshotRenderer → write PNG → `open`.
// Used to iterate on rendering/OCR thresholds without round-tripping
// through Xcode / device builds.

@main
struct RenderPreview {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            usage()
            exit(64)
        }

        let imagePath = args[1]
        let targetCode = args.count >= 3 ? args[2] : "zh-Hans"

        do {
            try await run(imagePath: imagePath, targetCode: targetCode)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func usage() {
        let msg = """
        usage: render-preview <image-path> [target-lang-code]

          Reads from environment:
            GEMINI_API_KEY (required)
            GEMINI_ENDPOINT (default: Gemini OpenAI-compat endpoint)
            GEMINI_MODEL    (default: gemini-2.5-flash)
            UNDERSTOOD      (comma-separated codes — boxes in these langs are left as-is.
                             Default: target,en)
            OCR_LANGUAGES   (comma-separated. Default: th-TH,en-US,zh-Hans,ja-JP,ko-KR)
            OUTPUT          (output PNG path. Default: /tmp/preview-<basename>.png)

        """
        FileHandle.standardError.write(Data(msg.utf8))
    }

    static func run(imagePath: String, targetCode: String) async throws {
        let imgURL = URL(fileURLWithPath: imagePath)
        guard let src = CGImageSourceCreateWithURL(imgURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CLIError("Cannot load image: \(imagePath)")
        }
        log("Image \(cg.width)x\(cg.height)")

        let env = ProcessInfo.processInfo.environment
        let apiKey = (env["GEMINI_API_KEY"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw CLIError("GEMINI_API_KEY is required")
        }
        let endpoint = env["GEMINI_ENDPOINT"]
            ?? "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        let model = env["GEMINI_MODEL"] ?? "gemini-2.5-flash"
        let ocrLanguages = (env["OCR_LANGUAGES"] ?? "th-TH,en-US,zh-Hans,ja-JP,ko-KR")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let understood = (env["UNDERSTOOD"] ?? "\(targetCode),en")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let targetName = SupportedLanguage.promptName(forCode: targetCode)

        let settings = AppSettings(
            targetLanguage: targetName,
            targetLanguageCode: targetCode,
            endpoint: endpoint,
            model: model,
            ocrLanguages: ocrLanguages,
            apiKey: apiKey,
            preferOnDeviceTranslation: false,
            understoodLanguages: understood
        )

        log("OCR …")
        let boxes = try await OCRService().recognizeText(in: cg, languageHints: ocrLanguages)
        log("  \(boxes.count) boxes")
        guard !boxes.isEmpty else { throw CLIError("No text recognised") }

        let texts = boxes.map(\.text)
        let toTranslate = LanguageDetector.indicesToTranslate(in: texts, understood: understood)
        let skipped = Set(0..<texts.count).subtracting(toTranslate)
        log("Translating \(toTranslate.count) (skipping \(skipped.count) in understood langs) …")

        var translations = texts
        if !toTranslate.isEmpty {
            let subset = toTranslate.map { texts[$0] }
            let translated = try await TranslationService().translate(
                subset,
                targetLanguage: targetName,
                settings: settings
            )
            for (offset, index) in toTranslate.enumerated() where offset < translated.count {
                translations[index] = translated[offset]
            }
        }

        log("Render …")
        let outCG = try ScreenshotRenderer().render(
            source: cg,
            boxes: boxes,
            translations: translations,
            skippedIndices: skipped
        )

        let baseName = imgURL.deletingPathExtension().lastPathComponent
        let outPath = env["OUTPUT"] ?? "/tmp/preview-\(baseName).png"
        let outURL = URL(fileURLWithPath: outPath)
        try writePNG(outCG, to: outURL)
        log("Wrote \(outURL.path)")

        // Diagnostics dump
        for (i, (box, t)) in zip(boxes, translations).enumerated() {
            let tag = skipped.contains(i) ? "skip" : "    "
            let rect = String(format: "(%4.0f,%4.0f %4.0fx%4.0f)",
                              box.rect.minX, box.rect.minY, box.rect.width, box.rect.height)
            log("[\(String(format: "%2d", i))] \(tag) \(rect) src=\"\(box.text)\" → \"\(t)\"")
        }

    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CLIError("Cannot create image destination at \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CLIError("Cannot finalize PNG output at \(url.path)")
        }
    }

    static func log(_ s: String) {
        FileHandle.standardError.write(Data("\(s)\n".utf8))
    }
}

struct CLIError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
