import UIKit

struct ScreenshotRenderer: Sendable {
    func render(
        source image: UIImage,
        boxes: [RecognizedTextBox],
        translations: [String],
        maskOpacity: Double
    ) throws -> UIImage {
        guard boxes.count == translations.count, let cgImage = image.cgImage else {
            throw TranslationError.invalidResponse
        }

        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let canvas = CGRect(origin: .zero, size: size)
        let neighborCeilings = Self.neighborCeilings(for: boxes, canvasHeight: size.height)

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))

            for (index, (box, translation)) in zip(boxes, translations).enumerated() {
                let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != box.text else { continue }

                let base = box.rect.insetBy(dx: -2, dy: -4)
                let downwardCeiling = neighborCeilings[index]
                let padded = expandedRect(
                    base: base,
                    for: trimmed,
                    minFontSize: 9,
                    canvas: canvas,
                    downwardCeiling: downwardCeiling
                )
                let palette = sampledPalette(from: cgImage, originalBox: box.rect)
                let background = palette.background.withAlphaComponent(maskOpacity)
                let path = UIBezierPath(roundedRect: padded, cornerRadius: min(8, padded.height / 4))
                background.setFill()
                path.fill()

                draw(
                    trimmed,
                    in: padded.insetBy(dx: 4, dy: 2),
                    context: context.cgContext,
                    foreground: palette.foreground
                )
            }
        }
    }

    private func expandedRect(
        base: CGRect,
        for text: String,
        minFontSize: CGFloat,
        canvas: CGRect,
        downwardCeiling: CGFloat
    ) -> CGRect {
        // Keep horizontal position/width identical to the source OCR box so the
        // translated text never drifts sideways into neighbouring UI elements.
        // If the translation needs more room than `minFontSize` can fit on one
        // line within the original width, grow the box downward to allow
        // wrapping — never sideways, and never past the next OCR box below.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: minFontSize, weight: .semibold)
        ]
        let measured = text.boundingRect(
            with: CGSize(width: max(1, base.width - 8), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        let neededHeight = ceil(measured.height) + 6
        guard neededHeight > base.height else {
            return base.intersection(canvas)
        }
        let absoluteCeiling = min(downwardCeiling, canvas.maxY)
        let availableHeight = max(base.height, absoluteCeiling - base.minY)
        let maxHeight = min(base.height * 3.0, availableHeight)
        let finalHeight = min(neededHeight, maxHeight)
        let expanded = CGRect(
            x: base.minX,
            y: base.minY,
            width: base.width,
            height: finalHeight
        )
        return expanded.intersection(canvas)
    }

    /// For each box, return the Y coordinate the box is allowed to grow down to —
    /// the top of the nearest other box that horizontally overlaps it and sits below.
    /// Boxes with no neighbour below get the canvas height.
    private static func neighborCeilings(for boxes: [RecognizedTextBox], canvasHeight: CGFloat) -> [CGFloat] {
        boxes.enumerated().map { index, box in
            var ceiling = canvasHeight
            for (otherIndex, other) in boxes.enumerated() where otherIndex != index {
                guard other.rect.minY >= box.rect.maxY - 1 else { continue }
                let horizontalOverlap = min(box.rect.maxX, other.rect.maxX) - max(box.rect.minX, other.rect.minX)
                guard horizontalOverlap > min(box.rect.width, other.rect.width) * 0.2 else { continue }
                if other.rect.minY < ceiling {
                    ceiling = other.rect.minY
                }
            }
            // Small padding so we don't kiss the next box's top.
            return max(box.rect.maxY, ceiling - 2)
        }
    }

    private func draw(_ text: String, in rect: CGRect, context: CGContext, foreground: UIColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let minFont: CGFloat = 9
        var fontSize = max(minFont, min(40, rect.height * 0.75))
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: foreground,
            .paragraphStyle: paragraph
        ]

        while fontSize > minFont {
            attributes[.font] = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            let measured = text.boundingRect(
                with: rect.size,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
            if measured.height <= rect.height && measured.width <= rect.width {
                break
            }
            fontSize -= 1
        }

        attributes[.font] = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let measured = text.boundingRect(
            with: rect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        // If even the minimum font doesn't fit, switch to tail truncation so we
        // get a visible ellipsis instead of text getting silently chopped at
        // the rect edge.
        if measured.height > rect.height || measured.width > rect.width {
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
        }

        let drawRect = CGRect(
            x: rect.minX,
            y: rect.minY + max(0, (rect.height - measured.height) / 2),
            width: rect.width,
            height: rect.height
        )
        text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
    }

    private struct ColorPalette {
        let foreground: UIColor
        let background: UIColor
    }

    /// Splits the pixels inside the OCR-detected `originalBox` into a "dark" cluster
    /// and a "bright" cluster by luminance midpoint, then assigns the larger cluster
    /// as the background and the smaller as the foreground. Falls back to white-bg /
    /// luminance-based-fg when contrast is too low to distinguish text from background.
    private func sampledPalette(from image: CGImage, originalBox: CGRect) -> ColorPalette {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return ColorPalette(foreground: .black, background: .white)
        }

        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let bytesPerRow = image.bytesPerRow
        let width = image.width
        let height = image.height
        let totalBytes = CFDataGetLength(data)

        let minX = max(0, Int(originalBox.minX))
        let maxX = min(width - 1, Int(originalBox.maxX))
        let minY = max(0, Int(originalBox.minY))
        let maxY = min(height - 1, Int(originalBox.maxY))
        guard maxX > minX, maxY > minY else {
            return ColorPalette(foreground: .black, background: .white)
        }

        let strideX = max(1, (maxX - minX) / 24)
        let strideY = max(1, (maxY - minY) / 12)

        var samples: [(r: Int, g: Int, b: Int, lum: CGFloat)] = []
        samples.reserveCapacity(256)
        var minLum: CGFloat = 1
        var maxLum: CGFloat = 0

        var y = minY
        while y <= maxY {
            var x = minX
            while x <= maxX {
                let offset = y * bytesPerRow + x * bytesPerPixel
                if offset + 2 < totalBytes {
                    let r = Int(bytes[offset])
                    let g = Int(bytes[offset + 1])
                    let b = Int(bytes[offset + 2])
                    let lum = (0.2126 * CGFloat(r) + 0.7152 * CGFloat(g) + 0.0722 * CGFloat(b)) / 255
                    samples.append((r, g, b, lum))
                    if lum < minLum { minLum = lum }
                    if lum > maxLum { maxLum = lum }
                }
                x += strideX
            }
            y += strideY
        }
        guard !samples.isEmpty else {
            return ColorPalette(foreground: .black, background: .white)
        }

        // Low contrast → can't reliably tell text from background; fall back.
        guard (maxLum - minLum) > 0.18 else {
            let avg = Self.average(samples)
            let bg = avg.color
            return ColorPalette(foreground: avg.lum > 0.55 ? .black : .white, background: bg)
        }

        let midpoint = (minLum + maxLum) / 2
        let darkCluster = samples.filter { $0.lum <= midpoint }
        let brightCluster = samples.filter { $0.lum > midpoint }
        guard !darkCluster.isEmpty, !brightCluster.isEmpty else {
            let avg = Self.average(samples)
            return ColorPalette(foreground: avg.lum > 0.55 ? .black : .white, background: avg.color)
        }

        let darkAvg = Self.average(darkCluster)
        let brightAvg = Self.average(brightCluster)

        // Larger cluster is the background (text covers fewer pixels than the page).
        if brightCluster.count >= darkCluster.count {
            return ColorPalette(foreground: darkAvg.color, background: brightAvg.color)
        } else {
            return ColorPalette(foreground: brightAvg.color, background: darkAvg.color)
        }
    }

    private static func average(_ samples: [(r: Int, g: Int, b: Int, lum: CGFloat)]) -> (color: UIColor, lum: CGFloat) {
        var rSum = 0, gSum = 0, bSum = 0
        var lSum: CGFloat = 0
        for s in samples {
            rSum += s.r
            gSum += s.g
            bSum += s.b
            lSum += s.lum
        }
        let n = CGFloat(samples.count)
        let color = UIColor(
            red: CGFloat(rSum) / n / 255,
            green: CGFloat(gSum) / n / 255,
            blue: CGFloat(bSum) / n / 255,
            alpha: 1
        )
        return (color, lSum / n)
    }
}
