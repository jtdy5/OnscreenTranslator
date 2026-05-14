import UIKit
import Vision

struct OCRService: Sendable {
    func recognizeText(in image: UIImage, languageHints: [String]) async throws -> [RecognizedTextBox] {
        guard let cgImage = image.cgImage else {
            throw TranslationError.unreadableImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let size = CGSize(width: cgImage.width, height: cgImage.height)
                let rawBoxes = observations.compactMap { observation -> RecognizedTextBox? in
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= 0.35 else {
                        return nil
                    }

                    let rect = Self.pixelRect(from: observation.boundingBox, imageSize: size)
                    guard rect.width > 8, rect.height > 6 else {
                        return nil
                    }

                    let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Drop boxes whose text is almost entirely punctuation/symbol noise
                    // (typical signature of icons or dotted dividers misread as text).
                    let letterDigitCount = trimmed.unicodeScalars.filter {
                        CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                    }.count
                    guard letterDigitCount * 3 >= trimmed.count else {
                        return nil
                    }

                    return RecognizedTextBox(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        rect: rect.integral
                    )
                }

                let deduped = Self.deduplicate(rawBoxes)
                let horizontallyMerged = Self.mergeAdjacent(deduped)
                let paragraphs = Self.mergeParagraphs(horizontallyMerged)
                continuation.resume(returning: paragraphs)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            if !languageHints.isEmpty {
                request.recognitionLanguages = languageHints
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func deduplicate(_ boxes: [RecognizedTextBox]) -> [RecognizedTextBox] {
        let sorted = boxes.sorted { lhs, rhs in
            if lhs.text.count != rhs.text.count {
                return lhs.text.count > rhs.text.count
            }
            return lhs.confidence > rhs.confidence
        }

        var kept: [RecognizedTextBox] = []
        for box in sorted {
            let overlapsExisting = kept.contains { other in
                overlapRatio(box.rect, other.rect) > 0.5
            }
            if !overlapsExisting {
                kept.append(box)
            }
        }
        return kept
    }

    /// Merge boxes that look like fragments of the same line — same row, similar
    /// height (proxy for same font size), small horizontal gap, and same detected
    /// language. Reduces the number of separate translation calls and gives the
    /// translator more context per chunk.
    private static func mergeAdjacent(_ boxes: [RecognizedTextBox]) -> [RecognizedTextBox] {
        guard boxes.count > 1 else { return boxes }
        let sorted = boxes.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > min(lhs.rect.height, rhs.rect.height) * 0.6 {
                return lhs.rect.midY < rhs.rect.midY
            }
            return lhs.rect.minX < rhs.rect.minX
        }

        let languages: [String?] = sorted.map { LanguageDetector.detect($0.text) }

        var merged: [RecognizedTextBox] = []
        var mergedLanguages: [String?] = []
        for (index, box) in sorted.enumerated() {
            let lang = languages[index]
            guard let last = merged.last else {
                merged.append(box)
                mergedLanguages.append(lang)
                continue
            }
            let lastLang = mergedLanguages.last ?? nil
            if Self.shouldMerge(last, box, lastLang: lastLang, candidateLang: lang) {
                let union = last.rect.union(box.rect)
                merged[merged.count - 1] = RecognizedTextBox(
                    id: last.id,
                    text: last.text + " " + box.text,
                    confidence: min(last.confidence, box.confidence),
                    rect: union.integral
                )
                if lastLang == nil {
                    mergedLanguages[mergedLanguages.count - 1] = lang
                }
            } else {
                merged.append(box)
                mergedLanguages.append(lang)
            }
        }
        return merged
    }

    private static func shouldMerge(
        _ a: RecognizedTextBox,
        _ b: RecognizedTextBox,
        lastLang: String?,
        candidateLang: String?
    ) -> Bool {
        let avgHeight = (a.rect.height + b.rect.height) / 2
        guard avgHeight > 0 else { return false }
        // Same row: vertical centers within 40% of average height. (Tighter than
        // before — 60% would occasionally merge boxes from two close lines.)
        let vCenterDelta = abs(a.rect.midY - b.rect.midY)
        guard vCenterDelta <= avgHeight * 0.4 else { return false }
        // Similar font size: heights within 50% of each other.
        let heightRatio = min(a.rect.height, b.rect.height) / max(a.rect.height, b.rect.height)
        guard heightRatio >= 0.5 else { return false }
        // Horizontal gap: ≤ ~1.4x avg height (≈ a couple of CJK chars / Latin words).
        let gap = b.rect.minX - a.rect.maxX
        guard gap >= -avgHeight * 0.3, gap <= avgHeight * 1.4 else { return false }
        // If both languages were detected and they differ at the base level, keep separate.
        if let lhs = lastLang, let rhs = candidateLang {
            if LanguageDetector.baseCode(lhs) != LanguageDetector.baseCode(rhs) {
                return false
            }
        }
        return true
    }

    /// After horizontal same-line merging, group vertically stacked lines that
    /// belong to the same paragraph (same chat bubble, same caption block) so
    /// the translator sees a coherent chunk rather than one fragmented line at
    /// a time. Without this, a 4-line Thai chat bubble produces 4 unrelated
    /// translations whose overlays stack and overlap each other.
    private static func mergeParagraphs(_ boxes: [RecognizedTextBox]) -> [RecognizedTextBox] {
        guard boxes.count > 1 else { return boxes }
        let sorted = boxes.sorted { $0.rect.minY < $1.rect.minY }
        let languages: [String?] = sorted.map { LanguageDetector.detect($0.text) }

        var merged: [RecognizedTextBox] = []
        var mergedLanguages: [String?] = []
        for (index, box) in sorted.enumerated() {
            let lang = languages[index]
            guard let last = merged.last else {
                merged.append(box)
                mergedLanguages.append(lang)
                continue
            }
            let lastLang = mergedLanguages.last ?? nil
            if Self.shouldJoinParagraph(last, box, lastLang: lastLang, candidateLang: lang) {
                let union = last.rect.union(box.rect)
                merged[merged.count - 1] = RecognizedTextBox(
                    id: last.id,
                    text: last.text + "\n" + box.text,
                    confidence: min(last.confidence, box.confidence),
                    rect: union.integral
                )
                if lastLang == nil {
                    mergedLanguages[mergedLanguages.count - 1] = lang
                }
            } else {
                merged.append(box)
                mergedLanguages.append(lang)
            }
        }
        return merged
    }

    private static func shouldJoinParagraph(
        _ a: RecognizedTextBox,
        _ b: RecognizedTextBox,
        lastLang: String?,
        candidateLang: String?
    ) -> Bool {
        let avgHeight = (a.rect.height + b.rect.height) / 2
        guard avgHeight > 0 else { return false }
        // Next line must be below the current paragraph (allow tiny overlap).
        guard b.rect.minY >= a.rect.maxY - avgHeight * 0.3 else { return false }
        // Vertical gap small enough to be the next line of the same paragraph.
        let gap = b.rect.minY - a.rect.maxY
        guard gap <= avgHeight * 1.2 else { return false }
        // Font sizes must be close (so we don't fuse heading + body).
        let heightRatio = min(a.rect.height, b.rect.height) / max(a.rect.height, b.rect.height)
        guard heightRatio >= 0.7 else { return false }
        // Horizontal overlap fraction (relative to the narrower line) must be
        // high — same column / same bubble.
        let hOverlap = min(a.rect.maxX, b.rect.maxX) - max(a.rect.minX, b.rect.minX)
        let narrower = min(a.rect.width, b.rect.width)
        guard narrower > 0, hOverlap >= narrower * 0.5 else { return false }
        // Same detected language (when both are detected).
        if let lhs = lastLang, let rhs = candidateLang,
           LanguageDetector.baseCode(lhs) != LanguageDetector.baseCode(rhs) {
            return false
        }
        return true
    }

    private static func overlapRatio(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let intersectionArea = intersection.width * intersection.height
        let smallerArea = min(a.width * a.height, b.width * b.height)
        guard smallerArea > 0 else { return 0 }
        return intersectionArea / smallerArea
    }

    private static func pixelRect(from normalizedRect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(
            x: normalizedRect.minX * imageSize.width,
            y: (1 - normalizedRect.maxY) * imageSize.height,
            width: normalizedRect.width * imageSize.width,
            height: normalizedRect.height * imageSize.height
        )
    }
}
