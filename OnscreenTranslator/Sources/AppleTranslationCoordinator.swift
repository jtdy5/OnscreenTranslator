import SwiftUI
import Translation

/// Bridge between non-UI code (`AppleTranslationService`) and SwiftUI's
/// `.translationTask` lifecycle.
///
/// SwiftUI explicitly refuses to drive `.translationTask` on a
/// `UIHostingController` embedded inside another hosting controller — and an
/// auxiliary `UIWindow` doesn't reliably run the task either, because SwiftUI
/// often skips lifecycle for windows that aren't the key window. The only
/// approach that works on real devices is to mount `.translationTask` inside
/// the app's main view hierarchy and trigger it from a coordinator.
///
/// Usage:
/// 1. The app attaches `AppleTranslationCoordinator.host(...)` to its root view.
/// 2. `AppleTranslationService` calls `requestSession(configuration:)`. The
///    coordinator updates its `@Published` configuration, SwiftUI invalidates
///    the modifier, `.translationTask` fires, and the resulting session is
///    delivered back via a continuation.
@available(iOS 18.0, *)
@MainActor
final class AppleTranslationCoordinator: ObservableObject {
    static let shared = AppleTranslationCoordinator()

    @Published fileprivate var configuration: TranslationSession.Configuration?
    private var continuation: CheckedContinuation<TranslationSession, Never>?

    private init() {}

    /// Ask SwiftUI for a fresh `TranslationSession` matching `configuration`.
    /// Serialized — the coordinator handles one request at a time, which
    /// matches how `AppleTranslationService.translate` actually drives it
    /// (one session per language group, in sequence).
    func requestSession(configuration: TranslationSession.Configuration) async -> TranslationSession {
        await withCheckedContinuation { cont in
            self.continuation = cont
            // Forcibly invalidate the current configuration so SwiftUI re-fires
            // the task even if the next configuration happens to be value-equal
            // to the previous one (e.g. the same source/target pair twice).
            self.configuration = nil
            DispatchQueue.main.async { [weak self] in
                self?.configuration = configuration
            }
        }
    }

    fileprivate func deliver(_ session: TranslationSession) {
        let cont = continuation
        continuation = nil
        configuration = nil
        cont?.resume(returning: session)
    }
}

/// Modifier the app attaches once to its root view. The view itself is a
/// zero-pixel `Color.clear`, but it lives inside the real SwiftUI hierarchy
/// where `.translationTask` is happy to run.
@available(iOS 18.0, *)
struct AppleTranslationHostModifier: ViewModifier {
    @ObservedObject var coordinator: AppleTranslationCoordinator

    func body(content: Content) -> some View {
        content.background(
            Color.clear
                .frame(width: 0, height: 0)
                .translationTask(coordinator.configuration) { session in
                    coordinator.deliver(session)
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
