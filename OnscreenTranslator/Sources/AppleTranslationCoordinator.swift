import SwiftUI
import Translation

/// Bridge between non-UI code (`AppleTranslationService`) and SwiftUI's
/// `.translationTask` lifecycle.
///
/// `TranslationSession` is bound to the `.translationTask` closure scope. The
/// framework asserts (fatal error: *"Attempted to use TranslationSession after
/// the view it was attached to has disappeared"*) if you store the session and
/// call `translations(from:)` outside the closure. So the coordinator does
/// **all** of the translation work inside the closure and only hands back the
/// already-collected `[Response]`.
///
/// Usage:
/// 1. The app attaches `mountAppleTranslationHost()` to its root view.
/// 2. `AppleTranslationService.translateBatch(configuration:requests:prepare:)`
///    sets the coordinator's pending job. SwiftUI invalidates the modifier,
///    `.translationTask` fires, the task closure runs `prepareTranslation()`
///    (if requested) and `session.translations(from:)`, then resumes the
///    continuation with the responses (or any error).
@available(iOS 18.0, *)
@MainActor
final class AppleTranslationCoordinator: ObservableObject {
    static let shared = AppleTranslationCoordinator()

    @Published fileprivate var configuration: TranslationSession.Configuration?

    fileprivate struct PendingJob {
        let requests: [TranslationSession.Request]
        let prepare: Bool
        let continuation: CheckedContinuation<[TranslationSession.Response], Error>
    }
    fileprivate var pending: PendingJob?

    private init() {}

    /// Run a batch of translation requests through SwiftUI's `.translationTask`.
    /// Returns the framework's responses, or throws whatever the framework
    /// threw. Serialized — one batch at a time, which matches the way
    /// `AppleTranslationService.translate` actually drives it.
    func translateBatch(
        configuration: TranslationSession.Configuration,
        requests: [TranslationSession.Request],
        prepare: Bool
    ) async throws -> [TranslationSession.Response] {
        try await withCheckedThrowingContinuation { cont in
            pending = PendingJob(requests: requests, prepare: prepare, continuation: cont)
            // Force a value change so SwiftUI re-fires `.translationTask` even
            // when the new configuration is value-equal to the last one.
            self.configuration = nil
            DispatchQueue.main.async { [weak self] in
                self?.configuration = configuration
            }
        }
    }

    fileprivate func runPendingJob(with session: TranslationSession) async {
        guard let job = pending else { return }
        pending = nil
        do {
            if job.prepare {
                try await session.prepareTranslation()
            }
            let responses = try await session.translations(from: job.requests)
            job.continuation.resume(returning: responses)
        } catch {
            job.continuation.resume(throwing: error)
        }
        // Drop the configuration so the next job's `requestSession` toggle
        // produces a clear identity change.
        configuration = nil
    }
}

/// Modifier the app attaches once to its root view. The Color.clear sits
/// inside the real SwiftUI hierarchy where `.translationTask` is happy to run.
@available(iOS 18.0, *)
struct AppleTranslationHostModifier: ViewModifier {
    @ObservedObject var coordinator: AppleTranslationCoordinator

    func body(content: Content) -> some View {
        content.background(
            Color.clear
                .frame(width: 0, height: 0)
                .translationTask(coordinator.configuration) { session in
                    await coordinator.runPendingJob(with: session)
                }
        )
    }
}

extension View {
    /// Mount the Apple Translation host inside the app's view hierarchy.
    @ViewBuilder
    func mountAppleTranslationHost() -> some View {
        if #available(iOS 18.0, *) {
            self.modifier(AppleTranslationHostModifier(coordinator: .shared))
        } else {
            self
        }
    }
}
