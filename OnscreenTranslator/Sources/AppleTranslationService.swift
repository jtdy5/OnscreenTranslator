import Foundation
import NaturalLanguage
import SwiftUI
import Translation
import UIKit

@available(iOS 18.0, *)
@MainActor
struct AppleTranslationService {
    func translate(
        _ texts: [String],
        targetLanguageCode: String,
        sourceLanguageHint: String? = nil
    ) async throws -> [String] {
        let targetBase = Self.baseCode(of: targetLanguageCode)

        let perBoxLanguage: [String?] = texts.map { text in
            guard Self.needsTranslation(text) else { return nil }
            return Self.detectLanguage(of: text)
        }

        let sessionSourceCode: String?
        if let hint = sourceLanguageHint, Self.baseCode(of: hint) != targetBase {
            sessionSourceCode = hint
        } else {
            sessionSourceCode = Self.dominantNonTargetLanguage(perBoxLanguage, targetBase: targetBase)
        }
        guard let sessionSourceCode else {
            throw TranslationError.appleLanguageUnavailable(
                "No box needs translating — all detected text already matches the target language."
            )
        }
        let sessionSourceBase = Self.baseCode(of: sessionSourceCode)

        let translatableIndices = perBoxLanguage.indices.filter { index in
            guard let lang = perBoxLanguage[index] else { return false }
            return Self.baseCode(of: lang) == sessionSourceBase
        }
        guard !translatableIndices.isEmpty else {
            throw TranslationError.appleLanguageUnavailable(
                "No box matched the chosen source language."
            )
        }

        let target = Locale.Language(identifier: targetLanguageCode)
        let source = Locale.Language(identifier: sessionSourceCode)

        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        switch status {
        case .unsupported:
            throw TranslationError.appleLanguageUnavailable(
                "Apple Translation does not support \(sessionSourceCode) → \(targetLanguageCode)."
            )
        case .installed, .supported:
            break
        @unknown default:
            throw TranslationError.appleLanguageUnavailable("Unknown Apple Translation availability state.")
        }

        let configuration = TranslationSession.Configuration(source: source, target: target)
        let session = try await acquireSession(configuration: configuration)

        if status == .supported {
            try await session.prepareTranslation()
        }

        let requests = translatableIndices.map { index in
            TranslationSession.Request(sourceText: texts[index], clientIdentifier: String(index))
        }
        let responses = try await session.translations(from: requests)

        var byIndex: [Int: String] = [:]
        for response in responses {
            if let id = response.clientIdentifier, let index = Int(id) {
                byIndex[index] = response.targetText
            }
        }
        return texts.enumerated().map { index, original in
            byIndex[index] ?? original
        }
    }

    private static func needsTranslation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        return trimmed.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    private static func detectLanguage(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    private static func dominantNonTargetLanguage(_ languages: [String?], targetBase: String) -> String? {
        var counts: [String: Int] = [:]
        for case let lang? in languages where baseCode(of: lang) != targetBase {
            counts[lang, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    private static func baseCode(of code: String) -> String {
        code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? code.lowercased()
    }

    private func acquireSession(
        configuration: TranslationSession.Configuration
    ) async throws -> TranslationSession {
        guard let window = Self.activeWindow() else {
            throw TranslationError.appleLanguageUnavailable(
                "No active app window available to host Apple Translation."
            )
        }

        let holder = SessionHolder()
        let host = UIHostingController(
            rootView: TranslationSessionHost(configuration: configuration) { session in
                holder.deliver(session)
            }
        )
        host.view.isUserInteractionEnabled = false
        host.view.isHidden = true
        host.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)

        if let root = window.rootViewController {
            root.addChild(host)
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
        } else {
            window.addSubview(host.view)
        }

        let session: TranslationSession
        do {
            session = try await withThrowingTaskGroup(of: TranslationSession.self) { group in
                group.addTask { await holder.wait() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    throw TranslationError.appleLanguageUnavailable(
                        "Apple Translation session did not start within 5 seconds."
                    )
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            throw error
        }

        return session
    }

    private static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
        guard let scene = active else { return nil }
        return scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
    }
}

@available(iOS 18.0, *)
private final class SessionHolder: @unchecked Sendable {
    private var session: TranslationSession?
    private var continuation: CheckedContinuation<TranslationSession, Never>?
    private let lock = NSLock()

    func deliver(_ session: TranslationSession) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: session)
        } else {
            self.session = session
            lock.unlock()
        }
    }

    func wait() async -> TranslationSession {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let session {
                self.session = nil
                lock.unlock()
                continuation.resume(returning: session)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

@available(iOS 18.0, *)
private struct TranslationSessionHost: View {
    let configuration: TranslationSession.Configuration
    let onSession: (TranslationSession) -> Void

    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                onSession(session)
            }
    }
}
