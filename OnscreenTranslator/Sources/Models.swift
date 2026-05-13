import Foundation
import CoreGraphics

struct RecognizedTextBox: Identifiable, Codable, Sendable {
    let id: UUID
    let text: String
    let confidence: Float
    let rect: CGRect

    init(id: UUID = UUID(), text: String, confidence: Float, rect: CGRect) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.rect = rect
    }
}

struct TranslationRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let targetLanguage: String
    let sourceImageName: String
    let outputImageName: String
    let recognizedCount: Int

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        targetLanguage: String,
        sourceImageName: String,
        outputImageName: String,
        recognizedCount: Int
    ) {
        self.id = id
        self.createdAt = createdAt
        self.targetLanguage = targetLanguage
        self.sourceImageName = sourceImageName
        self.outputImageName = outputImageName
        self.recognizedCount = recognizedCount
    }
}

enum TranslationError: LocalizedError {
    case missingImage
    case unreadableImage
    case noTextFound
    case missingAPIKey
    case invalidResponse
    case appleLanguageUnavailable(String)
    case timedOut(Double)
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingImage:
            "No screenshot was provided."
        case .unreadableImage:
            "The screenshot could not be decoded."
        case .noTextFound:
            "No readable text was found in the screenshot."
        case .missingAPIKey:
            "Add an API key in Settings before using cloud translation."
        case .invalidResponse:
            "The translation service returned an invalid response."
        case .appleLanguageUnavailable(let message):
            message
        case .timedOut(let seconds):
            "Translation timed out after \(Int(seconds)) seconds."
        case .requestFailed(let message):
            message
        }
    }
}
