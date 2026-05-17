import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var history: TranslationHistory

    var body: some View {
        TabView {
            TranslateView()
                .tabItem {
                    Label("Translate", systemImage: "text.viewfinder")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
        }
    }
}

private enum ProcessingStage: String {
    case recognizing = "Recognizing text…"
    case translating = "Translating…"
    case rendering = "Rendering…"
}

private struct TranslateView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var history: TranslationHistory
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?
    @State private var outputImage: UIImage?
    @State private var stage: ProcessingStage?
    @State private var errorMessage: String?
    @State private var savedToPhotosToast = false

    private var isProcessing: Bool { stage != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    instructions

                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Label("Choose Screenshot", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if let selectedImage {
                        PreviewImage(title: "Source", image: selectedImage)
                    }

                    Button {
                        Task { await translateSelectedImage() }
                    } label: {
                        if let stage {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text(stage.rawValue)
                            }
                        } else {
                            Label("Translate", systemImage: "wand.and.stars")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                    .disabled(selectedImage == nil || isProcessing)

                    if let outputImage {
                        PreviewImage(title: "Translated", image: outputImage)
                        Button {
                            saveToPhotos(outputImage)
                        } label: {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle("Onscreen Translator")
            .onChange(of: selectedItem) { _, newValue in
                Task { await loadImage(from: newValue) }
            }
            .alert("Translation", isPresented: errorBinding) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .overlay(alignment: .top) {
                if savedToPhotosToast {
                    Text("Saved to Photos")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func saveToPhotos(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        withAnimation { savedToPhotosToast = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { savedToPhotosToast = false }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One-tap translation from any app")
                .font(.headline)
            Text("""
            1. Open Shortcuts → + → Add three actions:
                • Take Screenshot
                • Translate Current Screenshot (from this app)
                • Quick Look
            2. Bind the Shortcut to a trigger:
                • Action Button (iPhone 15 Pro and later) — Settings → Action Button → Shortcut
                • Back Tap (any iPhone) — Settings → Accessibility → Touch → Back Tap
            3. In any app, trigger it — the translated screenshot pops up over the current screen.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func loadImage(from item: PhotosPickerItem?) async {
        errorMessage = nil
        outputImage = nil
        guard let item else { return }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw TranslationError.unreadableImage
            }
            selectedImage = image
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func translateSelectedImage() async {
        guard let selectedImage else { return }
        errorMessage = nil
        outputImage = nil

        defer { stage = nil }
        do {
            let settingsSnapshot = settings.snapshot()
            let working = ImageScaler.downscale(selectedImage)
            guard let workingCG = working.cgImage else {
                throw TranslationError.unreadableImage
            }

            stage = .recognizing
            let boxes = try await OCRService().recognizeText(
                in: workingCG,
                languageHints: settingsSnapshot.ocrLanguages
            )
            guard !boxes.isEmpty else {
                throw TranslationError.noTextFound
            }

            stage = .translating
            let result = try await BoxTranslator.translate(boxes: boxes, settings: settingsSnapshot)

            stage = .rendering
            // Dump per-box OCR/translation info to Documents so the user can
            // airdrop `last-ocr-diagnostic.txt` when reporting device-only
            // rendering issues.
            do {
                var lines: [String] = ["# OCR diagnostic — \(Date())"]
                for (i, (box, t)) in zip(boxes, result.translations).enumerated() {
                    let flag = result.skipped.contains(i) ? "skip" : "    "
                    let r = String(format: "(%4.0f,%4.0f %4.0fx%4.0f)",
                                   box.rect.minX, box.rect.minY, box.rect.width, box.rect.height)
                    let s = box.text.replacingOccurrences(of: "\n", with: "\\n")
                    let d = t.replacingOccurrences(of: "\n", with: "\\n")
                    lines.append("[\(String(format: "%2d", i))] \(flag) \(r) \(s) → \(d)")
                }
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                if let url = docs?.appendingPathComponent("last-ocr-diagnostic.txt") {
                    try? lines.joined(separator: "\n").data(using: .utf8)?.write(to: url, options: .atomic)
                }
            }
            let renderedCG = try ScreenshotRenderer().render(
                source: workingCG,
                boxes: boxes,
                translations: result.translations,
                skippedIndices: result.skipped
            )
            let image = UIImage(cgImage: renderedCG, scale: working.scale, orientation: working.imageOrientation)
            outputImage = image
            try history.add(
                outputImage: image,
                sourceImage: working,
                targetLanguage: settingsSnapshot.targetLanguage,
                recognizedCount: boxes.count
            )
            if let note = result.note {
                errorMessage = note
            }
        } catch {
            errorMessage = Self.userMessage(for: error)
        }
    }

    private static func userMessage(for error: Error) -> String {
        switch error {
        case TranslationError.missingAPIKey:
            return "Add a Gemini (or other OpenAI-compatible) API key in Settings to translate."
        case TranslationError.noTextFound:
            return "No readable text was found in this image."
        case TranslationError.unreadableImage:
            return "Could not read the selected image."
        case let TranslationError.requestFailed(message):
            if message.contains("RESOURCE_EXHAUSTED") || message.contains("quota") {
                return "Gemini quota exceeded. Wait a moment or upgrade your plan."
            }
            if message.contains("API_KEY_INVALID") || message.contains("401") {
                return "API key was rejected. Check Settings."
            }
            return "Translation request failed: \(message.prefix(200))"
        default:
            return error.localizedDescription
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    private var understoodLanguagesBinding: Binding<Set<String>> {
        Binding(
            get: {
                Set(settings.understoodLanguages
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty })
            },
            set: { codes in
                settings.understoodLanguages = SupportedLanguage.all
                    .map(\.code)
                    .filter { codes.contains($0) }
                    .joined(separator: ",")
            }
        )
    }

    private var understoodLanguagesSummary: String {
        let codes = settings.understoodLanguages
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let names = codes.compactMap { code in
            SupportedLanguage.all.first(where: { $0.code == code })?.displayName
        }
        guard !names.isEmpty else { return "None" }
        if names.count <= 2 { return names.joined(separator: ", ") }
        return "\(names.count) selected"
    }

    private var ocrLanguagesBinding: Binding<Set<String>> {
        Binding(
            get: {
                Set(settings.ocrLanguages
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty })
            },
            set: { codes in
                settings.ocrLanguages = SupportedLanguage.all
                    .map(\.ocrCode)
                    .filter { codes.contains($0) }
                    .joined(separator: ",")
            }
        )
    }

    private var selectedOCRLanguagesSummary: String {
        let codes = settings.ocrLanguages
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let names = SupportedLanguage.languages(forOCRCodes: codes).map(\.displayName)
        guard !names.isEmpty else { return "None" }
        if names.count <= 2 { return names.joined(separator: ", ") }
        return "\(names.count) selected"
    }

    private var targetLanguageBinding: Binding<String> {
        Binding(
            get: { settings.targetLanguageCode },
            set: { newCode in
                settings.targetLanguageCode = newCode
                settings.targetLanguage = SupportedLanguage.promptName(forCode: newCode)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Translation") {
                    Picker("Target language", selection: targetLanguageBinding) {
                        ForEach(SupportedLanguage.all) { language in
                            Text(language.displayName).tag(language.code)
                        }
                    }
                    Toggle("Fast on-device for Shortcut", isOn: $settings.preferOnDeviceTranslation)
                    Text("When triggered from Shortcuts, try Apple's on-device translation first (much faster). Falls back to the cloud model below if the language pair isn't installed or the call fails.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Defaults to Gemini 2.5 Flash via Google's OpenAI-compatible endpoint. Bring your own key from aistudio.google.com.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Endpoint", text: $settings.endpoint)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    TextField("Model", text: $settings.model)
                        .textInputAutocapitalization(.never)
                    SecureField("API key", text: $settings.apiKey)
                        .textInputAutocapitalization(.never)
                }

                Section("Languages You Understand") {
                    NavigationLink {
                        LanguagePicker(
                            selection: understoodLanguagesBinding,
                            title: "Understood Languages"
                        )
                    } label: {
                        HStack {
                            Text("Skip translating")
                            Spacer()
                            Text(understoodLanguagesSummary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text("Text detected in these languages stays in the original. Only other languages get translated into the target language.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("OCR") {
                    NavigationLink {
                        OCRLanguagesPicker(selection: ocrLanguagesBinding)
                    } label: {
                        HStack {
                            Text("Language hints")
                            Spacer()
                            Text(selectedOCRLanguagesSummary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text("Languages Vision should prioritize when reading text on-device. Add the ones you encounter — leaving extras in is fine.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Privacy") {
                    Text("Recognized text is sent to the configured cloud endpoint for translation. OCR runs on-device.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct LanguagePicker: View {
    @Binding var selection: Set<String>
    let title: String

    var body: some View {
        List {
            ForEach(SupportedLanguage.all) { language in
                Button {
                    if selection.contains(language.code) {
                        selection.remove(language.code)
                    } else {
                        selection.insert(language.code)
                    }
                } label: {
                    HStack {
                        Text(language.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selection.contains(language.code) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OCRLanguagesPicker: View {
    @Binding var selection: Set<String>

    var body: some View {
        List {
            ForEach(SupportedLanguage.all) { language in
                Button {
                    if selection.contains(language.ocrCode) {
                        selection.remove(language.ocrCode)
                    } else {
                        selection.insert(language.ocrCode)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(language.displayName)
                                .foregroundStyle(.primary)
                            Text(language.ocrCode)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection.contains(language.ocrCode) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
        .navigationTitle("OCR Languages")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HistoryView: View {
    @EnvironmentObject private var history: TranslationHistory
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(history.records) { record in
                    NavigationLink {
                        if let image = history.outputImage(for: record) {
                            PreviewImage(title: record.targetLanguage, image: image)
                                .padding()
                        } else {
                            ContentUnavailableView("Image Missing", systemImage: "photo")
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.targetLanguage)
                                .font(.headline)
                            Text("\(record.recognizedCount) text regions · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: history.remove(at:))
            }
            .overlay {
                if history.records.isEmpty {
                    ContentUnavailableView("No History", systemImage: "clock")
                }
            }
            .toolbar {
                Button("Clear All") {
                    confirmClear = true
                }
                .disabled(history.records.isEmpty)
            }
            .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) { history.clear() }
                Button("Cancel", role: .cancel) {}
            }
            .navigationTitle("History")
        }
    }
}

private struct PreviewImage: View {
    let title: String
    let image: UIImage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 1)
                }
        }
    }
}
