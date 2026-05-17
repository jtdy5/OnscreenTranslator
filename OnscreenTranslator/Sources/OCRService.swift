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

                // Adaptive confidence floor: keep boxes that are clearly above the
                // screenshot's own noise floor. Crisp UI screenshots have a high
                // median (0.9+) so we can comfortably drop weaker detections;
                // photo-text screenshots have a much lower median and we keep
                // more of them. A hard floor of 0.20 protects against pathological
                // inputs (e.g. an image of pure noise).
                let candidates = observations.compactMap { $0.topCandidates(1).first }
                let medianConfidence = Self.median(candidates.map { $0.confidence })
                let confidenceFloor = max(Float(0.20), medianConfidence * 0.5)

                let rawBoxes = observations.compactMap { observation -> RecognizedTextBox? in
                    guard let candidate = observation.topCandidates(1).first,
                          candidate.confidence >= confidenceFloor else {
                        return nil
                    }

                    let rect = Self.pixelRect(from: observation.boundingBox, imageSize: size)
                    guard rect.width > 8, rect.height > 6 else { return nil }

                    let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Reject only *tiny* tokens that are also mostly symbols. URLs,
                    // percentages, prices, hashtags etc. all pass through because
                    // they are longer than 3 characters.
                    let letterDigitCount = trimmed.unicodeScalars.filter {
                        CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
                    }.count
                    if trimmed.count <= 3, letterDigitCount * 2 < trimmed.count {
                        return nil
                    }

                    let glyphs = Self.glyphRects(for: candidate, range: candidate.string.startIndex..<candidate.string.endIndex, imageSize: size)
                    return RecognizedTextBox(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        rect: rect.integral,
                        glyphRects: glyphs
                    )
                }

                let deduped = Self.deduplicate(rawBoxes)
                let columnIds = Self.assignColumns(deduped, canvasWidth: size.width)
                let horizontallyMerged = Self.mergeAdjacent(deduped, columnIds: columnIds)
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

    // MARK: - Deduplication

    /// Two boxes are duplicates if they cover almost the same area AND their
    /// texts overlap heavily — that's the signature of Vision returning
    /// multiple candidates for the same glyphs. A small badge inside a larger
    /// card title looks like a near-100% area-overlap *with different text*
    /// and must be kept.
    private static func deduplicate(_ boxes: [RecognizedTextBox]) -> [RecognizedTextBox] {
        let sorted = boxes.sorted { lhs, rhs in
            if lhs.text.count != rhs.text.count { return lhs.text.count > rhs.text.count }
            return lhs.confidence > rhs.confidence
        }
        var kept: [RecognizedTextBox] = []
        for box in sorted {
            let conflicts = kept.contains { other in
                let area = overlapRatio(box.rect, other.rect)
                guard area > 0.85 else { return false }
                return Self.textSimilarity(box.text, other.text) > 0.5
            }
            if !conflicts { kept.append(box) }
        }
        return kept
    }

    // MARK: - Column detection

    /// Detect whether the screenshot is laid out in two (or more) columns by
    /// looking for a large empty horizontal gap between clusters of box
    /// left-edges. Returns a column id per box index (in the same order as
    /// `boxes`). When the layout is single-column every box gets the same id.
    private static func assignColumns(_ boxes: [RecognizedTextBox], canvasWidth: CGFloat) -> [Int] {
        guard boxes.count >= 6 else { return Array(repeating: 0, count: boxes.count) }
        // Cluster box centers (use box.rect.midX). Find the largest gap between
        // sorted centers — if it's > 25% of canvas and both sides have >= 3
        // members we declare a column split there.
        let centers = boxes.map(\.rect.midX).sorted()
        var maxGap: CGFloat = 0
        var splitX: CGFloat = 0
        for i in 1..<centers.count {
            let gap = centers[i] - centers[i - 1]
            if gap > maxGap {
                maxGap = gap
                splitX = (centers[i] + centers[i - 1]) / 2
            }
        }
        guard maxGap > canvasWidth * 0.25 else {
            return Array(repeating: 0, count: boxes.count)
        }
        let leftCount = boxes.filter { $0.rect.midX < splitX }.count
        let rightCount = boxes.count - leftCount
        guard leftCount >= 3, rightCount >= 3 else {
            return Array(repeating: 0, count: boxes.count)
        }
        return boxes.map { $0.rect.midX < splitX ? 0 : 1 }
    }

    // MARK: - Same-row merge

    /// Merge boxes that look like fragments of the same line — overlap
    /// vertically, similar height, small horizontal gap, same column, same
    /// language. The thresholds are computed from the screenshot's own
    /// statistics (median inter-box horizontal gap) so dense menus and large
    /// headlines both work without re-tuning.
    private static func mergeAdjacent(_ boxes: [RecognizedTextBox], columnIds: [Int]) -> [RecognizedTextBox] {
        guard boxes.count > 1 else { return boxes }

        // Pair indices with their column ids, sort by row order.
        let indexed = boxes.indices.map { ($0, boxes[$0], columnIds[$0]) }
        let sorted = indexed.sorted { lhs, rhs in
            if abs(lhs.1.rect.midY - rhs.1.rect.midY) > min(lhs.1.rect.height, rhs.1.rect.height) * 0.6 {
                return lhs.1.rect.midY < rhs.1.rect.midY
            }
            return lhs.1.rect.minX < rhs.1.rect.minX
        }

        let medianGap = Self.medianHorizontalGap(boxes)
        let languages: [String?] = sorted.map { LanguageDetector.detect($0.1.text) }

        var merged: [RecognizedTextBox] = []
        var mergedLanguages: [String?] = []
        var mergedColumns: [Int] = []
        for (sortIndex, entry) in sorted.enumerated() {
            let (_, box, column) = entry
            let lang = languages[sortIndex]
            guard let last = merged.last else {
                merged.append(box)
                mergedLanguages.append(lang)
                mergedColumns.append(column)
                continue
            }
            let lastLang = mergedLanguages.last ?? nil
            let lastColumn = mergedColumns.last ?? column
            if column == lastColumn,
               Self.shouldMerge(last, box, medianGap: medianGap, lastLang: lastLang, candidateLang: lang) {
                let union = last.rect.union(box.rect)
                merged[merged.count - 1] = RecognizedTextBox(
                    id: last.id,
                    text: last.text + " " + box.text,
                    confidence: min(last.confidence, box.confidence),
                    rect: union.integral,
                    glyphRects: last.glyphRects + box.glyphRects
                )
                if lastLang == nil {
                    mergedLanguages[mergedLanguages.count - 1] = lang
                }
            } else {
                merged.append(box)
                mergedLanguages.append(lang)
                mergedColumns.append(column)
            }
        }
        return merged
    }

    private static func shouldMerge(
        _ a: RecognizedTextBox,
        _ b: RecognizedTextBox,
        medianGap: CGFloat,
        lastLang: String?,
        candidateLang: String?
    ) -> Bool {
        let avgHeight = (a.rect.height + b.rect.height) / 2
        guard avgHeight > 0 else { return false }
        // Vertical projection overlap: same row if ranges share ≥ 50% of the
        // shorter box's height. Robust to descenders, subscripts, tone marks.
        let vOverlap = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
        let shorter = min(a.rect.height, b.rect.height)
        guard shorter > 0, vOverlap >= shorter * 0.5 else { return false }
        // Similar font size: heights within 50% of each other.
        let heightRatio = min(a.rect.height, b.rect.height) / max(a.rect.height, b.rect.height)
        guard heightRatio >= 0.5 else { return false }
        // Horizontal gap: tolerate up to 2× the screenshot's median inter-box
        // gap, with a small per-pair floor so single-row screenshots still
        // merge sensibly.
        let gap = b.rect.minX - a.rect.maxX
        let upperBound = max(medianGap * 2, avgHeight * 0.6)
        guard gap >= -avgHeight * 0.3, gap <= upperBound else { return false }
        // NB: we intentionally do NOT require same language here. Mixed-script
        // lines are the common case for chat / app UI ("ร้าน Saver" or
        // "KFC - Wachirathamsatit"); enforcing same-language splits a single
        // visual line into fragments that the translator then handles in
        // isolation — exactly the symptom we're trying to remove. Language
        // matching is still enforced for vertical paragraph merging.
        _ = lastLang
        _ = candidateLang
        return true
    }

    // MARK: - Paragraph merge

    /// After same-row merging, fuse vertically stacked lines that share a
    /// column. Thresholds are statistics-driven: vertical gap allowed is
    /// `1.6× medianLineSpacing`, computed across pairs whose horizontal
    /// projection overlap is ≥ 50%.
    private static func mergeParagraphs(_ boxes: [RecognizedTextBox]) -> [RecognizedTextBox] {
        guard boxes.count > 1 else { return boxes }
        let sorted = boxes.sorted { $0.rect.minY < $1.rect.minY }
        let languages: [String?] = sorted.map { LanguageDetector.detect($0.text) }
        let lineSpacing = Self.medianLineSpacing(sorted)

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
            if Self.shouldJoinParagraph(last, box, medianLineSpacing: lineSpacing, lastLang: lastLang, candidateLang: lang) {
                let union = last.rect.union(box.rect)
                merged[merged.count - 1] = RecognizedTextBox(
                    id: last.id,
                    text: last.text + "\n" + box.text,
                    confidence: min(last.confidence, box.confidence),
                    rect: union.integral,
                    glyphRects: last.glyphRects + box.glyphRects
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
        medianLineSpacing: CGFloat?,
        lastLang: String?,
        candidateLang: String?
    ) -> Bool {
        let avgHeight = (a.rect.height + b.rect.height) / 2
        guard avgHeight > 0 else { return false }
        // Next line must be below the current paragraph (allow tiny overlap).
        guard b.rect.minY >= a.rect.maxY - avgHeight * 0.3 else { return false }
        let gap = b.rect.minY - a.rect.maxY
        // Hard cap at 1.5× the line height — beyond that we're crossing a
        // section/card boundary, not a line break inside a paragraph. The
        // median-based bound from earlier observations adds a per-screenshot
        // softer ceiling on top of that.
        let hardCap = avgHeight * 1.5
        let softCap = medianLineSpacing.map { max($0 * 1.6, avgHeight * 0.6) } ?? (avgHeight * 1.2)
        let gapCap = min(hardCap, softCap)
        guard gap <= gapCap else { return false }
        // Font sizes must be close (so we don't fuse heading + body). The
        // ratio is loose because per-line bbox heights jitter heavily for
        // scripts with diacritics — a Thai line with stacked vowel marks
        // can be 60% taller than its neighbour at the same font size. 0.5
        // still catches headline-vs-body transitions (those are usually 2×+).
        let heightRatio = min(a.rect.height, b.rect.height) / max(a.rect.height, b.rect.height)
        guard heightRatio >= 0.5 else { return false }
        // Horizontal overlap fraction relative to the narrower line.
        let hOverlap = min(a.rect.maxX, b.rect.maxX) - max(a.rect.minX, b.rect.minX)
        let narrower = min(a.rect.width, b.rect.width)
        guard narrower > 0, hOverlap >= narrower * 0.5 else { return false }
        // Same language (when both are detected).
        if let lhs = lastLang, let rhs = candidateLang,
           LanguageDetector.baseCode(lhs) != LanguageDetector.baseCode(rhs) {
            return false
        }
        return true
    }

    // MARK: - Statistics helpers

    private static func median<T: Comparable & BinaryFloatingPoint>(_ values: [T]) -> T {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func medianHorizontalGap(_ boxes: [RecognizedTextBox]) -> CGFloat {
        guard boxes.count >= 2 else { return 0 }
        // Collect gaps between boxes that share a row (vertical overlap ≥ 50%).
        var gaps: [CGFloat] = []
        let byMidY = boxes.sorted { $0.rect.midY < $1.rect.midY }
        for i in 0..<byMidY.count {
            for j in (i + 1)..<byMidY.count {
                let a = byMidY[i], b = byMidY[j]
                if b.rect.midY - a.rect.midY > max(a.rect.height, b.rect.height) {
                    break
                }
                let vOverlap = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
                let shorter = min(a.rect.height, b.rect.height)
                guard shorter > 0, vOverlap >= shorter * 0.5 else { continue }
                let gap = abs(b.rect.minX - a.rect.maxX)
                if gap < shorter * 6 {
                    gaps.append(gap)
                }
            }
        }
        guard !gaps.isEmpty else { return 0 }
        return median(gaps)
    }

    private static func medianLineSpacing(_ sortedByMinY: [RecognizedTextBox]) -> CGFloat? {
        guard sortedByMinY.count >= 2 else { return nil }
        var spacings: [CGFloat] = []
        for i in 0..<(sortedByMinY.count - 1) {
            let a = sortedByMinY[i]
            for j in (i + 1)..<sortedByMinY.count {
                let b = sortedByMinY[j]
                let gap = b.rect.minY - a.rect.maxY
                guard gap >= 0 else { continue }
                // Skip gaps that are clearly across a section boundary — those
                // shouldn't influence the "typical line spacing" median. Lines
                // within a paragraph are typically <1.5× the line height apart.
                guard gap <= a.rect.height * 2 else { break }
                let hOverlap = min(a.rect.maxX, b.rect.maxX) - max(a.rect.minX, b.rect.minX)
                let narrower = min(a.rect.width, b.rect.width)
                guard narrower > 0, hOverlap >= narrower * 0.5 else { continue }
                spacings.append(gap)
                break
            }
        }
        guard spacings.count >= 3 else { return nil }
        return median(spacings)
    }

    private static func textSimilarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a.unicodeScalars)
        let setB = Set(b.unicodeScalars)
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    // MARK: - Glyph rects

    /// Best-effort per-character bounding rects within the observation. Used by
    /// the renderer to sample colours from glyph pixels (foreground) versus
    /// gaps (background). Falls back to an empty array on older OSes or when
    /// the Vision API refuses the range.
    private static func glyphRects(
        for candidate: VNRecognizedText,
        range: Range<String.Index>,
        imageSize: CGSize
    ) -> [CGRect] {
        var rects: [CGRect] = []
        var cursor = candidate.string.startIndex
        let end = candidate.string.endIndex
        while cursor < end {
            let next = candidate.string.index(after: cursor)
            if let observation = (try? candidate.boundingBox(for: cursor..<next)).flatMap({ $0 }) {
                let pixel = pixelRect(from: observation.boundingBox, imageSize: imageSize)
                if pixel.width > 0, pixel.height > 0 {
                    rects.append(pixel)
                }
            }
            cursor = next
        }
        return rects
    }

    // MARK: - Geometry helpers

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
