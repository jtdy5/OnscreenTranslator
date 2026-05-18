import Foundation
import UIKit

/// Persists every translation run to a timestamped folder under
/// `Documents/runs/<yyyy-MM-dd_HH-mm-ss>/`. Each folder contains:
///   - `source.png`     — the input screenshot (post any pre-render scaling)
///   - `output.png`     — the rendered translated image
///   - `diagnostic.txt` — per-box OCR rect / source text / translation / skip
///
/// Lets the user accumulate multiple test runs and share the whole batch
/// in one go (via Files app → On My iPhone → Onscreen Translator → runs).
enum DebugArchive {
    static func save(
        source: UIImage,
        output: UIImage,
        boxes: [RecognizedTextBox],
        translations: [String],
        skipped: Set<Int>,
        targetLanguage: String,
        entryPoint: String
    ) {
        guard let folder = runFolder() else { return }
        if let sourceData = source.pngData() {
            try? sourceData.write(to: folder.appendingPathComponent("source.png"), options: .atomic)
        }
        if let outputData = output.pngData() {
            try? outputData.write(to: folder.appendingPathComponent("output.png"), options: .atomic)
        }
        var lines: [String] = []
        lines.append("# OCR diagnostic")
        lines.append("# generated: \(Date())")
        lines.append("# entry: \(entryPoint)")
        lines.append("# target: \(targetLanguage)")
        lines.append("# columns: index | flag | rect(x,y,w,h) | source → translation")
        for (i, (box, t)) in zip(boxes, translations).enumerated() {
            let flag = skipped.contains(i) ? "skip" : "    "
            let r = String(format: "(%4.0f,%4.0f %4.0fx%4.0f)",
                           box.rect.minX, box.rect.minY, box.rect.width, box.rect.height)
            let src = box.text.replacingOccurrences(of: "\n", with: "\\n")
            let dst = t.replacingOccurrences(of: "\n", with: "\\n")
            lines.append("[\(String(format: "%2d", i))] \(flag) \(r) \(src) → \(dst)")
        }
        if let logData = lines.joined(separator: "\n").data(using: .utf8) {
            try? logData.write(to: folder.appendingPathComponent("diagnostic.txt"), options: .atomic)
        }
    }

    /// Create (or return) a unique per-run folder under Documents/runs/.
    /// Folder name is the run's timestamp; on the unlikely collision (two
    /// runs in the same second) a numeric suffix is appended.
    private static func runFolder() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let runs = docs.appendingPathComponent("runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let base = formatter.string(from: Date())
        var candidate = runs.appendingPathComponent(base, isDirectory: true)
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = runs.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        do {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return candidate
    }
}
