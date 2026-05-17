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
    ///
    /// `allowed` (when non-empty) constrains `NLLanguageRecognizer` to those
    /// language codes. Without constraints NL happily classifies a Latin-script
    /// brand name like "Wachirathamsatit" as Indonesian / Malay / Tagalog —
    /// languages that look identical to English on short inputs. Pass the
    /// user's understood languages + target + OCR hints here so detection only
    /// chooses from languages that are actually relevant for this screenshot.
    static func detect(_ text: String, allowed: [String] = []) -> String? {
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
        let constraints = Self.nlLanguages(for: allowed)
        if !constraints.isEmpty {
            recognizer.languageConstraints = constraints
        }
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

    /// Map raw BCP-47-ish codes to `NLLanguage` values. Handles common region
    /// suffixes (`th-TH`, `zh-Hans-CN`, `en-US`) and silently drops anything
    /// `NLLanguage` doesn't recognize.
    private static func nlLanguages(for codes: [String]) -> [NLLanguage] {
        var seen = Set<NLLanguage>()
        var result: [NLLanguage] = []
        for code in codes {
            let candidates = [code, baseCode(code)]
            for candidate in candidates {
                let lang = NLLanguage(rawValue: candidate)
                // NLLanguage init never returns nil; it returns `.undetermined`
                // for unrecognized strings. Filter those out explicitly.
                if lang != .undetermined, !seen.contains(lang) {
                    seen.insert(lang)
                    result.append(lang)
                    break
                }
            }
        }
        return result
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
    /// the user already understands.
    ///
    /// The decision is **script-based**, not NL-classification-based. A text is
    /// translated iff it contains at least one letter character whose script is
    /// NOT in the understood-script set (after the pure-numeric / URL / handle
    /// filter). Rationale: NL classification of mixed-language lines is
    /// fragile — a Thai line containing an English brand name ("ร้าน Saver")
    /// is often classified as English, and would otherwise be skipped, leaving
    /// the Thai parts on screen untranslated. Looking at scripts directly
    /// catches every line that has *any* glyph the user can't read.
    ///
    /// Pure-Latin content stays untranslated when the user understands a Latin
    /// language (English). Pure-Han content stays untranslated when the user
    /// understands Chinese. Anything with mixed-in foreign-script glyphs goes
    /// through the translator.
    static func indicesToTranslate(
        in texts: [String],
        understood: [String],
        allowedDetectionLanguages: [String] = []
    ) -> [Int] {
        _ = allowedDetectionLanguages   // accepted for API compatibility; unused
        let understoodScripts = Set(understood.map { expectedScript(forLanguageCode: $0) })
        return texts.indices.filter { i in
            let text = texts[i]
            if shouldSkipTranslation(text) { return false }
            return Self.containsScriptOutside(understoodScripts, in: text)
        }
    }

    /// True if any letter / CJK glyph in `text` belongs to a script outside the
    /// understood set. Cyrillic when the user only reads Latin+Han, Thai when
    /// the user reads Latin+Han, etc. Non-letter characters (digits, symbols,
    /// punctuation) are ignored. Han / Hiragana / Katakana are folded together
    /// for "CJK" purposes, so Japanese text is correctly classified as foreign
    /// for a Chinese-only user.
    private static func containsScriptOutside(_ understood: Set<Script>, in text: String) -> Bool {
        // Treat understood scripts plus their CJK siblings as known: someone
        // who understands Chinese will also recognise Han glyphs that appear
        // in Japanese, and vice versa for kana variants.
        var allowed = understood
        let cjk: Set<Script> = [.han, .hiragana, .katakana]
        if !allowed.isDisjoint(with: cjk) {
            allowed.formUnion(cjk)
        }
        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) || isCJK(scalar) else { continue }
            let script = scriptOf(scalar)
            if script == .unknown { continue }
            if !allowed.contains(script) {
                return true
            }
        }
        return false
    }

    /// True if `text` mixes two or more letter scripts (e.g. Latin + Thai —
    /// a Thai sentence with an English proper noun, or vice versa). Used by
    /// paragraph merging to keep mixed-script lines tied to their siblings
    /// even when dominantScript would classify each line into a different
    /// language.
    static func containsMultipleScripts(_ text: String) -> Bool {
        var seen = Set<Script>()
        for scalar in text.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) || isCJK(scalar) else { continue }
            let script = scriptOf(scalar)
            guard script != .unknown else { continue }
            seen.insert(script)
            // Fold CJK siblings together — Han + Hiragana isn't "mixed" in
            // the sense that matters here.
            let cjk: Set<Script> = [.han, .hiragana, .katakana]
            let cjkSeen = seen.intersection(cjk)
            let nonCjkSeen = seen.subtracting(cjk)
            if (cjkSeen.isEmpty ? 0 : 1) + nonCjkSeen.count >= 2 {
                return true
            }
        }
        return false
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
