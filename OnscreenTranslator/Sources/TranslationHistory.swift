import UIKit

@MainActor
final class TranslationHistory: ObservableObject {
    @Published private(set) var records: [TranslationRecord] = []

    init() {
        load()
    }

    func add(outputImage: UIImage, sourceImage: UIImage, targetLanguage: String, recognizedCount: Int) throws {
        let id = UUID()
        let sourceName = "\(id.uuidString)-source.png"
        let outputName = "\(id.uuidString)-translated.png"
        try ImageStorage.save(sourceImage, name: sourceName)
        try ImageStorage.save(outputImage, name: outputName)

        let record = TranslationRecord(
            id: id,
            targetLanguage: targetLanguage,
            sourceImageName: sourceName,
            outputImageName: outputName,
            recognizedCount: recognizedCount
        )
        records.insert(record, at: 0)
        persist()
    }

    func outputImage(for record: TranslationRecord) -> UIImage? {
        ImageStorage.load(name: record.outputImageName)
    }

    func remove(_ record: TranslationRecord) {
        ImageStorage.delete(name: record.sourceImageName)
        ImageStorage.delete(name: record.outputImageName)
        records.removeAll { $0.id == record.id }
        persist()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets {
            let record = records[index]
            ImageStorage.delete(name: record.sourceImageName)
            ImageStorage.delete(name: record.outputImageName)
        }
        records.remove(atOffsets: offsets)
        persist()
    }

    func clear() {
        for record in records {
            ImageStorage.delete(name: record.sourceImageName)
            ImageStorage.delete(name: record.outputImageName)
        }
        records.removeAll()
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Keys.history),
              let decoded = try? JSONDecoder().decode([TranslationRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded
    }

    private func persist() {
        let data = try? JSONEncoder().encode(records)
        UserDefaults.standard.set(data, forKey: Keys.history)
    }
}

enum ImageStorage {
    static func save(_ image: UIImage, name: String) throws {
        guard let data = image.pngData() else {
            throw TranslationError.unreadableImage
        }
        try data.write(to: url(for: name), options: .atomic)
    }

    static func load(name: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: name).path)
    }

    static func delete(name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    static func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("TranslatedScreenshots", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder
    }
}
