import Foundation
import NaturalLanguage
import SwiftUI
import Translation
import UIKit

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
        // the target or look like pure numerics/URLs/handles.
        let sourcePerIndex: [String?] = texts.map { text in
            if LanguageDetector.shouldSkipTranslation(text) { return nil }
            guard let detected = LanguageDetector.detect(text) else { return nil }
            if LanguageDetector.baseCode(detected) == targetBase { return nil }
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
            let session: TranslationSession
            do {
                session = try await acquireSession(configuration: configuration)
            } catch {
                unsupportedLanguages.append(sourceCode)
                continue
            }

            if status == .supported {
                do { try await session.prepareTranslation() } catch {
                    unsupportedLanguages.append(sourceCode)
                    continue
                }
            }

            let requests = indices.map { index in
                TranslationSession.Request(sourceText: texts[index], clientIdentifier: String(index))
            }
            let responses: [TranslationSession.Response]
            do {
                responses = try await session.translations(from: requests)
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

    // MARK: - Session acquisition

    private func acquireSession(
        configuration: TranslationSession.Configuration
    ) async throws -> TranslationSession {
        guard let window = Self.activeWindow() else {
            throw TranslationError.appleLanguageUnavailable(
                "No active app window available to host Apple Translation. Open the app to the foreground at least once to install the translation model."
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

        defer {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }

        do {
            return try await withThrowingTaskGroup(of: TranslationSession.self) { group in
                group.addTask { await holder.wait() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 12_000_000_000)
                    throw TranslationError.appleLanguageUnavailable(
                        "Apple Translation session did not start within 12 seconds."
                    )
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } catch {
            throw error
        }
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
