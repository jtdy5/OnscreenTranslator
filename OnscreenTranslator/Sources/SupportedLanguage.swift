import Foundation

struct SupportedLanguage: Identifiable, Hashable, Sendable {
    let displayName: String
    let code: String
    let ocrCode: String

    var id: String { code }

    init(displayName: String, code: String, ocrCode: String? = nil) {
        self.displayName = displayName
        self.code = code
        self.ocrCode = ocrCode ?? code
    }

    static let all: [SupportedLanguage] = [
        .init(displayName: "Chinese (Simplified) 简体中文", code: "zh-Hans", ocrCode: "zh-Hans"),
        .init(displayName: "Chinese (Traditional) 繁體中文", code: "zh-Hant", ocrCode: "zh-Hant"),
        .init(displayName: "English", code: "en", ocrCode: "en-US"),
        .init(displayName: "Japanese 日本語", code: "ja", ocrCode: "ja-JP"),
        .init(displayName: "Korean 한국어", code: "ko", ocrCode: "ko-KR"),
        .init(displayName: "Thai ภาษาไทย", code: "th", ocrCode: "th-TH"),
        .init(displayName: "Vietnamese Tiếng Việt", code: "vi", ocrCode: "vi-VT"),
        .init(displayName: "Indonesian Bahasa", code: "id", ocrCode: "id-ID"),
        .init(displayName: "Malay Bahasa Melayu", code: "ms", ocrCode: "ms-MY"),
        .init(displayName: "Tagalog", code: "tl", ocrCode: "tl-PH"),
        .init(displayName: "Spanish Español", code: "es", ocrCode: "es-ES"),
        .init(displayName: "French Français", code: "fr", ocrCode: "fr-FR"),
        .init(displayName: "German Deutsch", code: "de", ocrCode: "de-DE"),
        .init(displayName: "Portuguese Português", code: "pt", ocrCode: "pt-BR"),
        .init(displayName: "Italian Italiano", code: "it", ocrCode: "it-IT"),
        .init(displayName: "Russian Русский", code: "ru", ocrCode: "ru-RU"),
        .init(displayName: "Arabic العربية", code: "ar", ocrCode: "ar-SA"),
        .init(displayName: "Hindi हिन्दी", code: "hi", ocrCode: "hi-IN"),
        .init(displayName: "Turkish Türkçe", code: "tr", ocrCode: "tr-TR")
    ]

    static func languages(forOCRCodes codes: [String]) -> [SupportedLanguage] {
        codes.compactMap { code in
            all.first(where: { $0.ocrCode == code || $0.code == code })
        }
    }

    static func displayName(forCode code: String) -> String {
        all.first(where: { $0.code == code })?.displayName ?? code
    }

    static func promptName(forCode code: String) -> String {
        let raw = displayName(forCode: code)
        return raw.split(separator: " ").first.map(String.init) ?? raw
    }

    static func match(code: String) -> SupportedLanguage? {
        all.first(where: { $0.code == code })
    }
}
