import Foundation
import NaturalLanguage

enum LanguageDetector {
    /// Coarse Unicode-block classification of a text's dominant script. Used by
    /// the renderer + the LLM retry path to reason about "is this still the
    /// source language?" without hardcoding per-language code-point ranges.
    enum Script: String {
        case han, latin, thai, arabic, hiragana, katakana, hangul, cyrillic, devanagari, hebrew, mixed, unknown
    }

    /// Returns BCP-47 base code (e.g. "zh", "en", "th") of the dominant language in `text`,
    /// or nil if detection fails or the text is too short / has no letters worth classifying.
    /// Lowers the minimum length to 1 when the text contains CJK code points — a single
    /// Chinese character is enough to classify reliably and worth treating as "understood".
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hasCJK = trimmed.unicodeScalars.contains { Self.isCJK($0) }
        if !hasCJK {
            guard trimmed.count >= 2,
                  trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
                return nil
            }
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        if let language = recognizer.dominantLanguage {
            return language.rawValue
        }
        // NLLanguageRecognizer occasionally fails on lone CJK glyphs — synthesize a
        // best-guess code so callers still have something to compare against.
        if hasCJK {
            return "zh"
        }
        return nil
    }

    static func baseCode(_ code: String) -> String {
        code.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map(String.init)?
            .lowercased() ?? code.lowercased()
    }

    /// Texts that are pure numerals, currency amounts, percentages, time stamps,
    /// codes, URLs, emails, or @/# handles should never be translated regardless
    /// of the user's "understood" list. Pre-merge this filter saves spurious LLM
    /// calls and stops Apple Translation from butchering brand codes.
    static func shouldSkipTranslation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // Pure numeric / currency / percentage / time / unit. The negative
        // guard rejects strings that contain CJK or Thai *letters* — the
        // currency-symbol U+0E3F (฿) lives in the Thai block but is a symbol,
        // not a letter, so `฿164` correctly passes through.
        let numericPattern = #"^[\p{Sc}]?[\d][\d,.\s:/%\-+×x]*[\p{Sc}\w]{0,4}$"#
        if trimmed.range(of: numericPattern, options: .regularExpression) != nil,
           !trimmed.unicodeScalars.contains(where: {
               CharacterSet.letters.contains($0) && (Self.isCJK($0) || Self.isThai($0))
           }) {
            return true
        }
        // URLs / emails / handles.
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return true
        }
        if trimmed.contains("@"), trimmed.contains(".") {
            // Looks like email or domain handle.
            return true
        }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix("@") {
            let body = String(trimmed.dropFirst())
            if body.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) {
                return true
            }
        }
        return false
    }

    /// Returns indices of `texts` that should be translated, given a set of language codes
    /// the user already understands. Texts whose detected language matches an understood
    /// language (compared by base code) are skipped. Texts that look like numerics / URLs /
    /// handles are also skipped (see `shouldSkipTranslation`). Texts where detection fails
    /// fall through to "translate" — safer than leaving foreign script on screen.
    static func indicesToTranslate(in texts: [String], understood: [String]) -> [Int] {
        let understoodBases = Set(understood.map(baseCode))
        return texts.indices.filter { i in
            if shouldSkipTranslation(texts[i]) { return false }
            guard let detected = detect(texts[i]) else { return true }
            return !understoodBases.contains(baseCode(detected))
        }
    }

    /// Dominant Unicode script of a string, used to detect when an LLM output is
    /// still in the source script (retry trigger) without hardcoding per-pair
    /// code-point ranges.
    static func dominantScript(of text: String) -> Script {
        var counts: [Script: Int] = [:]
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) || isCJK(scalar) {
            counts[scriptOf(scalar), default: 0] += 1
        }
        guard let top = counts.max(by: { $0.value < $1.value }) else {
            return .unknown
        }
        let total = counts.values.reduce(0, +)
        // If the leading script doesn't account for at least 60% of the
        // letters/glyphs, call it mixed.
        if total > 0, Double(top.value) / Double(total) < 0.6 {
            return .mixed
        }
        return top.key
    }

    /// The expected script for a BCP-47 target language code. Used by the LLM
    /// retry to decide whether a translation came back in the right script.
    static func expectedScript(forLanguageCode code: String) -> Script {
        let base = baseCode(code)
        switch base {
        case "zh", "yue", "ja-han": return .han
        case "ja": return .hiragana // ja text is mostly hiragana with han + katakana mixed in; treat as hiragana-dominant
        case "ko": return .hangul
        case "th": return .thai
        case "ar", "fa", "ur": return .arabic
        case "he", "yi": return .hebrew
        case "ru", "uk", "bg", "be", "sr", "mk", "kk": return .cyrillic
        case "hi", "mr", "ne", "sa": return .devanagari
        default: return .latin
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // CJK Unified Ideographs, Extension A/B + ranges; Hiragana, Katakana, Hangul.
        return (0x3040...0x309F).contains(v)     // Hiragana
            || (0x30A0...0x30FF).contains(v)     // Katakana
            || (0x3400...0x4DBF).contains(v)     // CJK Ext A
            || (0x4E00...0x9FFF).contains(v)     // CJK Unified
            || (0xAC00...0xD7AF).contains(v)     // Hangul Syllables
            || (0x1100...0x11FF).contains(v)     // Hangul Jamo
            || (0x20000...0x2A6DF).contains(v)   // CJK Ext B
    }

    private static func isThai(_ scalar: Unicode.Scalar) -> Bool {
        (0x0E00...0x0E7F).contains(scalar.value)
    }

    private static func scriptOf(_ scalar: Unicode.Scalar) -> Script {
        let v = scalar.value
        if (0x3040...0x309F).contains(v) { return .hiragana }
        if (0x30A0...0x30FF).contains(v) { return .katakana }
        if (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0x20000...0x2A6DF).contains(v) { return .han }
        if (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) { return .hangul }
        if (0x0E00...0x0E7F).contains(v) { return .thai }
        if (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v) || (0xFB50...0xFDFF).contains(v) || (0xFE70...0xFEFF).contains(v) { return .arabic }
        if (0x0590...0x05FF).contains(v) { return .hebrew }
        if (0x0400...0x04FF).contains(v) || (0x0500...0x052F).contains(v) { return .cyrillic }
        if (0x0900...0x097F).contains(v) || (0xA8E0...0xA8FF).contains(v) { return .devanagari }
        if (0x0020...0x024F).contains(v) || (0x1E00...0x1EFF).contains(v) { return .latin }
        return .unknown
    }
}
