import Foundation
import NaturalLanguage

enum LanguageDetector {
    /// Returns BCP-47 base code (e.g. "zh", "en", "th") of the dominant language in `text`,
    /// or nil if detection fails or the text has no letters worth classifying.
    static func detect(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2,
              trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return nil
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        return recognizer.dominantLanguage?.rawValue
    }

    static func baseCode(_ code: String) -> String {
        code.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map(String.init)?
            .lowercased() ?? code.lowercased()
    }

    /// Returns indices of `texts` that should be translated, given a set of language codes
    /// the user already understands. Texts whose detected language matches an understood
    /// language (compared by base code) are skipped; texts where detection fails are
    /// included (safer to translate than to leave foreign text in place).
    static func indicesToTranslate(in texts: [String], understood: [String]) -> [Int] {
        let understoodBases = Set(understood.map(baseCode))
        return texts.indices.filter { i in
            guard let detected = detect(texts[i]) else { return true }
            return !understoodBases.contains(baseCode(detected))
        }
    }
}
