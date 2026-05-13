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
                          candidate.confidence >= 0.2 else {
                        return nil
                    }

                    let rect = Self.pixelRect(from: observation.boundingBox, imageSize: size)
                    guard rect.width > 8, rect.height > 6 else {
                        return nil
                    }

                    return RecognizedTextBox(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        rect: rect.integral
                    )
                }

                let boxes = Self.deduplicate(rawBoxes)
                continuation.resume(returning: boxes)
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
