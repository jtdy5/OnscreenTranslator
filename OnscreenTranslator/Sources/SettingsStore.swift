import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var targetLanguage: String {
        didSet { UserDefaults.standard.set(targetLanguage, forKey: Keys.targetLanguage) }
    }

    @Published var targetLanguageCode: String {
        didSet { UserDefaults.standard.set(targetLanguageCode, forKey: Keys.targetLanguageCode) }
    }

    @Published var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: Keys.endpoint) }
    }

    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Keys.model) }
    }

    @Published var ocrLanguages: String {
        didSet { UserDefaults.standard.set(ocrLanguages, forKey: Keys.ocrLanguages) }
    }

    @Published var apiKey: String {
        didSet { KeychainStore.save(apiKey, service: Keys.service, account: Keys.apiKey) }
    }

    @Published var maskOpacity: Double {
        didSet { UserDefaults.standard.set(maskOpacity, forKey: Keys.maskOpacity) }
    }

    @Published var preferOnDeviceTranslation: Bool {
        didSet { UserDefaults.standard.set(preferOnDeviceTranslation, forKey: Keys.preferOnDeviceTranslation) }
    }

    @Published var understoodLanguages: String {
        didSet { UserDefaults.standard.set(understoodLanguages, forKey: Keys.understoodLanguages) }
    }

    init() {
        targetLanguage = UserDefaults.standard.string(forKey: Keys.targetLanguage) ?? "Chinese"
        targetLanguageCode = UserDefaults.standard.string(forKey: Keys.targetLanguageCode) ?? "zh-Hans"
        endpoint = UserDefaults.standard.string(forKey: Keys.endpoint) ?? "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
        model = UserDefaults.standard.string(forKey: Keys.model) ?? "gemini-2.5-flash"
        ocrLanguages = UserDefaults.standard.string(forKey: Keys.ocrLanguages) ?? "th-TH,zh-Hans,en-US,ja-JP,ko-KR"
        apiKey = KeychainStore.read(service: Keys.service, account: Keys.apiKey) ?? Self.bundledAPIKey() ?? ""
        let storedOpacity = UserDefaults.standard.object(forKey: Keys.maskOpacity) as? Double
        maskOpacity = storedOpacity ?? 0.88
        let storedPreference = UserDefaults.standard.object(forKey: Keys.preferOnDeviceTranslation) as? Bool
        preferOnDeviceTranslation = storedPreference ?? true
        let storedUnderstood = UserDefaults.standard.string(forKey: Keys.understoodLanguages)
        understoodLanguages = storedUnderstood ?? (UserDefaults.standard.string(forKey: Keys.targetLanguageCode) ?? "zh-Hans")
    }

    func snapshot() -> AppSettings {
        AppSettings(
            targetLanguage: targetLanguage,
            targetLanguageCode: targetLanguageCode,
            endpoint: endpoint,
            model: model,
            ocrLanguages: parsedOCRLanguages,
            apiKey: apiKey,
            maskOpacity: maskOpacity,
            preferOnDeviceTranslation: preferOnDeviceTranslation,
            understoodLanguages: parsedUnderstoodLanguages
        )
    }

    private var parsedUnderstoodLanguages: [String] {
        understoodLanguages
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated static func bundledAPIKey() -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "GeminiAPIKey") as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var parsedOCRLanguages: [String] {
        ocrLanguages
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct AppSettings: Sendable {
    let targetLanguage: String
    let targetLanguageCode: String
    let endpoint: String
    let model: String
    let ocrLanguages: [String]
    let apiKey: String
    let maskOpacity: Double
    let preferOnDeviceTranslation: Bool
    let understoodLanguages: [String]

    static func fromDefaults() -> AppSettings {
        let targetCode = UserDefaults.standard.string(forKey: Keys.targetLanguageCode) ?? "zh-Hans"
        return AppSettings(
            targetLanguage: UserDefaults.standard.string(forKey: Keys.targetLanguage) ?? "Chinese",
            targetLanguageCode: targetCode,
            endpoint: UserDefaults.standard.string(forKey: Keys.endpoint) ?? "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            model: UserDefaults.standard.string(forKey: Keys.model) ?? "gemini-2.5-flash",
            ocrLanguages: (UserDefaults.standard.string(forKey: Keys.ocrLanguages) ?? "th-TH,zh-Hans,en-US,ja-JP,ko-KR")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            apiKey: KeychainStore.read(service: Keys.service, account: Keys.apiKey) ?? SettingsStore.bundledAPIKey() ?? "",
            maskOpacity: UserDefaults.standard.object(forKey: Keys.maskOpacity) as? Double ?? 0.88,
            preferOnDeviceTranslation: UserDefaults.standard.object(forKey: Keys.preferOnDeviceTranslation) as? Bool ?? true,
            understoodLanguages: (UserDefaults.standard.string(forKey: Keys.understoodLanguages) ?? targetCode)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

enum Keys {
    static let service = "OnscreenTranslator"
    static let targetLanguage = "targetLanguage"
    static let targetLanguageCode = "targetLanguageCode"
    static let endpoint = "translationEndpoint"
    static let model = "translationModel"
    static let ocrLanguages = "ocrLanguages"
    static let apiKey = "translationAPIKey"
    static let maskOpacity = "maskOpacity"
    static let preferOnDeviceTranslation = "preferOnDeviceTranslation"
    static let understoodLanguages = "understoodLanguages"
    static let history = "translationHistory"
}
