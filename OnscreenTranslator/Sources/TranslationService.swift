import Foundation

struct TranslationService: Sendable {
    /// Cap on the total source characters per LLM call. We pack indices into
    /// batches that don't exceed this number; paragraph-merged boxes with very
    /// long combined text get their own batch instead of bloating a group of
    /// 25 short items.
    private static let maxCharsPerBatch = 4000

    func translate(_ texts: [String], targetLanguage: String, settings: AppSettings) async throws -> [String] {
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.missingAPIKey
        }
        guard let url = URL(string: settings.endpoint) else {
            throw TranslationError.requestFailed("The translation endpoint URL is invalid.")
        }

        var output = texts
        let translatableIndices = texts.indices.filter { Self.needsTranslation(texts[$0]) }
        guard !translatableIndices.isEmpty else { return output }

        try await runChunkedTranslation(
            indices: translatableIndices,
            into: &output,
            sourceTexts: texts,
            targetLanguage: targetLanguage,
            targetLanguageCode: settings.targetLanguageCode,
            settings: settings,
            url: url,
            isRetry: false
        )

        let stuckIndices = translatableIndices.filter { index in
            Self.outputStillInSourceScript(output[index], targetLanguageCode: settings.targetLanguageCode)
        }
        if !stuckIndices.isEmpty {
            try await runChunkedTranslation(
                indices: stuckIndices,
                into: &output,
                sourceTexts: texts,
                targetLanguage: targetLanguage,
                targetLanguageCode: settings.targetLanguageCode,
                settings: settings,
                url: url,
                isRetry: true
            )
        }
        return output
    }

    private func runChunkedTranslation(
        indices: [Int],
        into output: inout [String],
        sourceTexts: [String],
        targetLanguage: String,
        targetLanguageCode: String,
        settings: AppSettings,
        url: URL,
        isRetry: Bool
    ) async throws {
        let chunks = Self.chunkByCharacterBudget(indices: indices, sourceTexts: sourceTexts, budget: Self.maxCharsPerBatch)
        let results = try await withThrowingTaskGroup(of: (Int, [String]).self) { group -> [(Int, [String])] in
            for (chunkIndex, chunk) in chunks.enumerated() {
                let texts = chunk.map { sourceTexts[$0] }
                group.addTask {
                    let translated = try await translateChunk(
                        texts,
                        targetLanguage: targetLanguage,
                        settings: settings,
                        url: url,
                        isRetry: isRetry
                    )
                    return (chunkIndex, translated)
                }
            }
            var collected: [(Int, [String])] = []
            for try await result in group {
                collected.append(result)
            }
            return collected.sorted { $0.0 < $1.0 }
        }

        for (chunkIndex, translated) in results {
            let chunk = chunks[chunkIndex]
            for (offset, originalIndex) in chunk.enumerated() {
                if offset < translated.count {
                    output[originalIndex] = translated[offset]
                }
            }
        }
    }

    /// Pack indices into chunks whose combined source-text length stays under
    /// `budget`. A single item that already exceeds the budget gets its own
    /// chunk — we still send it (the upstream LLM may truncate, which is fine;
    /// silently dropping it would be worse).
    private static func chunkByCharacterBudget(indices: [Int], sourceTexts: [String], budget: Int) -> [[Int]] {
        var chunks: [[Int]] = []
        var current: [Int] = []
        var currentLen = 0
        for i in indices {
            let length = sourceTexts[i].count
            if !current.isEmpty, currentLen + length > budget {
                chunks.append(current)
                current = [i]
                currentLen = length
            } else {
                current.append(i)
                currentLen += length
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// True when the LLM's output is still dominated by a script that doesn't
    /// match the user's target language — script-agnostic so it works for any
    /// (source, target) pair.
    private static func outputStillInSourceScript(_ text: String, targetLanguageCode: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        let observed = LanguageDetector.dominantScript(of: trimmed)
        let expected = LanguageDetector.expectedScript(forLanguageCode: targetLanguageCode)
        if observed == .unknown || observed == .mixed { return false }
        // Han/Hiragana/Katakana are all acceptable for Chinese/Japanese targets.
        let cjkScripts: Set<LanguageDetector.Script> = [.han, .hiragana, .katakana]
        if cjkScripts.contains(expected), cjkScripts.contains(observed) {
            return false
        }
        return observed != expected
    }

    private static func needsTranslation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        let letters = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty
    }

    private func translateChunk(
        _ texts: [String],
        targetLanguage: String,
        settings: AppSettings,
        url: URL,
        isRetry: Bool = false
    ) async throws -> [String] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        let systemPrompt: String
        if isRetry {
            systemPrompt = """
            You MUST translate every input item into \(targetLanguage). Do NOT return any item unchanged.
            Input JSON: {"items":[{"i":<int>,"t":"<text>"},...]}.
            Output JSON ONLY: {"translations":[{"i":<int>,"t":"<\(targetLanguage) translation>"},...]}.
            Echo each "i" exactly. One output per input.
            Even for proper nouns, brand names, dish names, and place names — transliterate or describe them in \(targetLanguage). Never echo non-\(targetLanguage) script back.
            Examples: Thai "ผัดกะเพรา" → "罗勒炒饭"; "สุขุมวิท" → "素坤逸"; "ดาวเรียง" → "排排星".
            """
        } else {
            systemPrompt = """
            Translate every input item into \(targetLanguage).
            Input is JSON: {"items":[{"i":<int>,"t":"<text>"},...]}.
            Return ONLY JSON: {"translations":[{"i":<int>,"t":"<translation>"},...]}.
            Each output entry MUST echo the same "i" as its source input. Return one entry per input — never merge, split, drop, or reorder.
            If an item contains ANY text not in \(targetLanguage), translate the whole item into \(targetLanguage). Transliterate proper nouns and dish names into \(targetLanguage) script — do NOT echo the original script back.
            Only return text unchanged when it is entirely a number, currency, percentage, code, URL, or pure symbol with no translatable words.
            Keep each translation concise enough to fit into the original UI box.
            """
        }

        let payload = ChatCompletionRequest(
            model: settings.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: encodedInput(for: texts))
            ],
            temperature: isRetry ? 0.3 : 0.1,
            reasoning_effort: settings.model.contains("2.5") ? "none" : nil
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await sendWithRetry(request: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw TranslationError.requestFailed(message)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content,
              let jsonData = content.data(using: .utf8) else {
            throw TranslationError.invalidResponse
        }

        if ProcessInfo.processInfo.environment["DEBUG_TRANSLATION"] != nil {
            FileHandle.standardError.write(Data("--- raw LLM content ---\n\(content)\n--- end ---\n".utf8))
        }
        let result: TranslationResult
        do {
            result = try JSONDecoder().decode(TranslationResult.self, from: cleanedJSONData(jsonData, raw: content))
        } catch {
            throw TranslationError.requestFailed("Could not parse translator JSON: \(error.localizedDescription). Raw: \(content.prefix(500))")
        }
        var byIndex: [Int: String] = [:]
        for entry in result.translations {
            byIndex[entry.i] = entry.t
        }
        return texts.enumerated().map { index, original in
            byIndex[index] ?? original
        }
    }

    private func sendWithRetry(request: URLRequest) async throws -> (Data, URLResponse) {
        var attempt = 0
        let maxRetries = 3
        while true {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (http.statusCode == 429 || (500...599).contains(http.statusCode)),
                  attempt < maxRetries else {
                return (data, response)
            }
            attempt += 1
            let body = String(data: data, encoding: .utf8) ?? ""
            let suggested = Self.retryDelay(fromBody: body) ?? Double(1 << attempt)
            let delay = min(suggested, 30)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private static func retryDelay(fromBody body: String) -> Double? {
        guard let range = body.range(of: #""retryDelay"\s*:\s*"([0-9.]+)s""#, options: .regularExpression) else {
            return nil
        }
        let match = body[range]
        guard let numberRange = match.range(of: #"[0-9.]+"#, options: .regularExpression) else {
            return nil
        }
        return Double(match[numberRange])
    }

    private func encodedInput(for texts: [String]) -> String {
        let payload = TranslationInput(items: texts.enumerated().map { TranslationInput.Item(i: $0.offset, t: $0.element) })
        let data = (try? JSONEncoder().encode(payload)) ?? Data()
        return String(data: data, encoding: .utf8) ?? #"{"items":[]}"#
    }

    private func cleanedJSONData(_ data: Data, raw: String) -> Data {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let lines = trimmed.split(separator: "\n").dropFirst().dropLast()
            return Data(lines.joined(separator: "\n").utf8)
        }
        return data
    }
}

private struct TranslationInput: Encodable {
    struct Item: Encodable {
        let i: Int
        let t: String
    }
    let items: [Item]
}

private struct TranslationResult: Decodable {
    struct Entry: Decodable {
        let i: Int
        let t: String
    }
    let translations: [Entry]
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let reasoning_effort: String?
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ChatMessage
    }
}
