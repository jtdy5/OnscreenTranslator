import Foundation
import Translation

@available(iOS 18.0, *)
@MainActor
struct AppleTranslationService {
    /// Translate the texts the caller has already decided need translating.
    /// Texts are grouped by detected source language so a screenshot with
    /// Thai + Japanese + English all gets translated correctly. Each language
    /// group runs its own `TranslationSession`; texts whose source language
    /// is unsupported are returned unchanged.
    func translate(
        _ texts: [String],
        targetLanguageCode: String
    ) async throws -> [String] {
        let targetBase = LanguageDetector.baseCode(targetLanguageCode)
        // Detect each text's source language and skip those that already match
        // the target or look like pure numerics/URLs/handles. Require at least
        // 2 letters/CJK glyphs of evidence in the text before honouring the
        // detected language — otherwise one stray Korean glyph mixed into a
        // Thai paragraph would spawn an entire Korean session.
        let sourcePerIndex: [String?] = texts.map { text in
            if LanguageDetector.shouldSkipTranslation(text) { return nil }
            guard let detected = LanguageDetector.detect(text) else { return nil }
            if LanguageDetector.baseCode(detected) == targetBase { return nil }
            let evidence = text.unicodeScalars.filter {
                CharacterSet.letters.contains($0) ||
                (0x3040...0x9FFF).contains($0.value) ||
                (0xAC00...0xD7AF).contains($0.value)
            }.count
            guard evidence >= 2 else { return nil }
            return detected
        }

        // Group indices by source language base code.
        var groups: [String: [Int]] = [:]
        for (i, src) in sourcePerIndex.enumerated() {
            guard let src else { continue }
            groups[LanguageDetector.baseCode(src), default: []].append(i)
        }
        guard !groups.isEmpty else {
            throw TranslationError.appleLanguageUnavailable(
                "Nothing to translate — every input either matched the target or looked like a passthrough token."
            )
        }

        var output = texts
        var translatedAtLeastOne = false
        var unsupportedLanguages: [String] = []
        let availability = LanguageAvailability()
        let target = Locale.Language(identifier: targetLanguageCode)

        for (sourceCode, indices) in groups {
            let source = Locale.Language(identifier: sourceCode)
            let status = await availability.status(from: source, to: target)
            switch status {
            case .unsupported:
                unsupportedLanguages.append(sourceCode)
                continue
            case .installed, .supported:
                break
            @unknown default:
                unsupportedLanguages.append(sourceCode)
                continue
            }

            let configuration = TranslationSession.Configuration(source: source, target: target)
            let requests = indices.map { index in
                TranslationSession.Request(sourceText: texts[index], clientIdentifier: String(index))
            }

            let responses: [TranslationSession.Response]
            do {
                responses = try await runBatch(
                    configuration: configuration,
                    requests: requests,
                    prepare: status == .supported
                )
            } catch {
                unsupportedLanguages.append(sourceCode)
                continue
            }

            for response in responses {
                if let id = response.clientIdentifier, let index = Int(id) {
                    output[index] = response.targetText
                    translatedAtLeastOne = true
                }
            }
        }

        if !translatedAtLeastOne {
            throw TranslationError.appleLanguageUnavailable(
                unsupportedLanguages.isEmpty
                    ? "Apple Translation produced no output."
                    : "Apple Translation does not support: \(unsupportedLanguages.joined(separator: ", ")) → \(targetLanguageCode)."
            )
        }
        return output
    }

    // MARK: - Session batch

    /// Run a translation batch through SwiftUI's `.translationTask` host
    /// (mounted on the app's root view by `AppleTranslationCoordinator`). The
    /// `TranslationSession` is used only inside the `.translationTask` closure
    /// — required by the framework, which fatal-errors if the session is
    /// touched after that closure returns.
    private func runBatch(
        configuration: TranslationSession.Configuration,
        requests: [TranslationSession.Request],
        prepare: Bool
    ) async throws -> [TranslationSession.Response] {
        try await withThrowingTaskGroup(of: [TranslationSession.Response].self) { group in
            group.addTask { @MainActor in
                try await AppleTranslationCoordinator.shared.translateBatch(
                    configuration: configuration,
                    requests: requests,
                    prepare: prepare
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                throw TranslationError.appleLanguageUnavailable(
                    "Apple Translation did not respond within 15 seconds. Open the app to the foreground at least once so the host view is mounted."
                )
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
