import Foundation

struct TranslationService: Sendable {
    private static let batchSize = 25

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
            settings: settings,
            url: url,
            isRetry: false
        )

        let stuckIndices = translatableIndices.filter { index in
            Self.containsForeignScript(output[index], targetLanguage: targetLanguage)
        }
        if !stuckIndices.isEmpty {
            try await runChunkedTranslation(
                indices: stuckIndices,
                into: &output,
                sourceTexts: texts,
                targetLanguage: targetLanguage,
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
        settings: AppSettings,
        url: URL,
        isRetry: Bool
    ) async throws {
        let chunks = indices.chunked(into: Self.batchSize)
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

    private static func containsForeignScript(_ text: String, targetLanguage: String) -> Bool {
        let isChineseTarget = targetLanguage.lowercased().contains("chinese") || targetLanguage.contains("中文")
        for scalar in text.unicodeScalars {
            if (0x0E00...0x0E7F).contains(scalar.value) { return true }
            if (0x1100...0x11FF).contains(scalar.value) || (0xAC00...0xD7AF).contains(scalar.value) {
                if isChineseTarget { return true }
            }
            if (0x3040...0x30FF).contains(scalar.value) {
                if isChineseTarget { return true }
            }
        }
        return false
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

        let result = try JSONDecoder().decode(TranslationResult.self, from: cleanedJSONData(jsonData, raw: content))
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

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
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
