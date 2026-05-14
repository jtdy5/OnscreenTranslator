import SwiftUI

@main
struct OnscreenTranslatorApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var history = TranslationHistory()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(history)
                .mountAppleTranslationHost()
        }
    }
}
