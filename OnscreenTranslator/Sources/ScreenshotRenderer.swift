import UIKit

struct ScreenshotRenderer: Sendable {
    /// Render the translated overlay onto `image`.
    ///
    /// - Parameter skippedIndices: boxes that were intentionally left
    ///   untranslated (e.g. detected as a language the user already
    ///   understands). These get no mask at all — the source pixels show
    ///   through unchanged. Boxes outside this set are always masked, even
    ///   when translation came back identical to the source (treat as a
    ///   silent translation failure rather than letting the source bleed).
    func render(
        source image: UIImage,
        boxes: [RecognizedTextBox],
        translations: [String],
        skippedIndices: Set<Int> = []
    ) throws -> UIImage {
        guard boxes.count == translations.count, let cgImage = image.cgImage else {
            throw TranslationError.invalidResponse
        }

        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let canvas = CGRect(origin: .zero, size: size)
        let downwardCeilings = Self.neighborCeilings(for: boxes, canvasHeight: size.height)
        let upwardFloors = Self.neighborFloors(for: boxes)

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))

            for (index, (box, translation)) in zip(boxes, translations).enumerated() {
                if skippedIndices.contains(index) { continue }
                let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
                // Translation succeeded when we got back something non-empty
                // that differs from the source. Otherwise we still draw the
                // mask (so the source can't bleed through), but skip the text
                // — there's nothing meaningful to put on top.
                let hasTranslation = !trimmed.isEmpty && trimmed != box.text

                // Pad vertically enough to swallow ascenders/descenders and
                // diacritics (Thai vowel marks, Devanagari matras) that sit
                // outside the OCR baseline box. Without this, the original
                // glyph tops bleed out above the mask.
                let base = box.rect.insetBy(dx: -3, dy: -7)
                let downwardCeiling = downwardCeilings[index]
                let upwardFloor = upwardFloors[index]
                let targetFontSize = min(box.rect.height * 0.82, 34)
                let padded = hasTranslation
                    ? expandedRect(
                        base: base,
                        for: trimmed,
                        targetFontSize: targetFontSize,
                        canvas: canvas,
                        downwardCeiling: downwardCeiling,
                        upwardFloor: upwardFloor
                    )
                    : base.intersection(canvas)
                let palette = sampledPalette(from: cgImage, box: box)
                let path = UIBezierPath(roundedRect: padded, cornerRadius: min(8, padded.height / 4))
                // Always opaque: anything below 1.0 lets the original glyphs
                // ghost through, since the OCR box sits right on the source text.
                palette.background.setFill()
                path.fill()

                guard hasTranslation else { continue }
                draw(
                    trimmed,
                    in: padded.insetBy(dx: 4, dy: 2),
                    context: context.cgContext,
                    foreground: palette.foreground,
                    targetFontSize: targetFontSize
                )
            }
        }
    }

    // MARK: - Rect expansion

    private func expandedRect(
        base: CGRect,
        for text: String,
        targetFontSize: CGFloat,
        canvas: CGRect,
        downwardCeiling: CGFloat,
        upwardFloor: CGFloat
    ) -> CGRect {
        // Horizontal width/position is locked to the source OCR box. If the
        // translation doesn't fit at `targetFontSize` we grow the rect first
        // downward up to the neighbouring box's top edge, then — when that
        // isn't enough — upward up to the box above. We never grow sideways.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: targetFontSize, weight: .semibold)
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
        let absoluteFloor = max(upwardFloor, canvas.minY)
        let downwardRoom = max(0, absoluteCeiling - base.maxY)
        let upwardRoom = max(0, base.minY - absoluteFloor)

        // Hard cap growth at 1.6× the original line height. Beyond that we
        // shrink the font instead — letting one translation expand 2-3 lines
        // tall reliably collides with neighbouring translations and produces
        // a confusing, misaligned overlay.
        let maxHeight = min(base.height + downwardRoom + upwardRoom, base.height * 1.6)
        let finalHeight = min(neededHeight, maxHeight)
        let extra = finalHeight - base.height

        // Spend the room downward first, then upward.
        let growDown = min(extra, downwardRoom)
        let growUp = min(extra - growDown, upwardRoom)
        let expanded = CGRect(
            x: base.minX,
            y: base.minY - growUp,
            width: base.width,
            height: base.height + growUp + growDown
        )
        return expanded.intersection(canvas)
    }

    /// For each box, the Y coordinate it is allowed to grow downward to —
    /// the top of the nearest other box that horizontally overlaps it and
    /// sits below. Boxes with no neighbour below get the canvas height.
    private static func neighborCeilings(for boxes: [RecognizedTextBox], canvasHeight: CGFloat) -> [CGFloat] {
        boxes.enumerated().map { index, box in
            var ceiling = canvasHeight
            for (otherIndex, other) in boxes.enumerated() where otherIndex != index {
                guard other.rect.minY >= box.rect.maxY - 1 else { continue }
                let horizontalOverlap = min(box.rect.maxX, other.rect.maxX) - max(box.rect.minX, other.rect.minX)
                guard horizontalOverlap > min(box.rect.width, other.rect.width) * 0.2 else { continue }
                if other.rect.minY < ceiling { ceiling = other.rect.minY }
            }
            return max(box.rect.maxY, ceiling - 2)
        }
    }

    /// For each box, the Y coordinate above the box that it is allowed to grow
    /// upward to — the bottom of the nearest box that horizontally overlaps it
    /// and sits above. Boxes with no neighbour above get 0 (top of canvas).
    private static func neighborFloors(for boxes: [RecognizedTextBox]) -> [CGFloat] {
        boxes.enumerated().map { index, box in
            var floor: CGFloat = 0
            for (otherIndex, other) in boxes.enumerated() where otherIndex != index {
                guard other.rect.maxY <= box.rect.minY + 1 else { continue }
                let horizontalOverlap = min(box.rect.maxX, other.rect.maxX) - max(box.rect.minX, other.rect.minX)
                guard horizontalOverlap > min(box.rect.width, other.rect.width) * 0.2 else { continue }
                if other.rect.maxY > floor { floor = other.rect.maxY }
            }
            return min(box.rect.minY, floor + 2)
        }
    }

    // MARK: - Text drawing

    private func draw(
        _ text: String,
        in rect: CGRect,
        context: CGContext,
        foreground: UIColor,
        targetFontSize: CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        // Chinese/Japanese/Korean glyphs don't need Latin-style leading;
        // tightening the line height makes multi-line translations fit
        // their source line height much more often.
        paragraph.lineHeightMultiple = 0.95

        // Start at the target font size (visually matching the source UI).
        // Two shrink passes: comfortable lower bound 8pt, last-ditch 6pt
        // before truncation kicks in.
        let comfortFloor: CGFloat = 8
        let lastDitchFloor: CGFloat = 6
        var fontSize = max(comfortFloor, min(40, targetFontSize))
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: foreground,
            .paragraphStyle: paragraph
        ]

        func fits(_ size: CGFloat) -> Bool {
            attributes[.font] = UIFont.systemFont(ofSize: size, weight: .semibold)
            let measured = text.boundingRect(
                with: rect.size,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
            return measured.height <= rect.height && measured.width <= rect.width
        }

        while fontSize > comfortFloor, !fits(fontSize) {
            fontSize -= 1
        }
        // If the comfortable floor still overflows AND we're in a tight rect,
        // grant one extra pass down to 6pt before truncating. Above that we'd
        // rather show a `…`.
        if !fits(fontSize), rect.height < 14, fontSize > lastDitchFloor {
            while fontSize > lastDitchFloor, !fits(fontSize) {
                fontSize -= 1
            }
        }

        attributes[.font] = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let measured = text.boundingRect(
            with: rect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
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

    // MARK: - Colour palette

    private struct ColorPalette {
        let foreground: UIColor
        let background: UIColor
    }

    /// Sample foreground/background colours for the translation overlay.
    ///
    /// Strategy in order of preference:
    /// 1. If Vision gave us per-glyph rects, sample foreground from inside the
    ///    glyphs and background from gaps outside the glyphs. This works on
    ///    gradients, photos, and translucent overlays because we're looking at
    ///    where the actual text pixels live rather than the box as a whole.
    /// 2. Otherwise, fall back to inset luminance clustering — sample pixels
    ///    inside an inset of the OCR box, split them at the midpoint of the
    ///    observed luminance range, treat the bigger cluster as background.
    /// 3. If contrast is too low (no clear text/background distinction), use
    ///    the overall average colour as background and pick black/white for
    ///    the foreground.
    private func sampledPalette(from image: CGImage, box: RecognizedTextBox) -> ColorPalette {
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

        if !box.glyphRects.isEmpty, let palette = Self.glyphBoundedPalette(
            bytes: bytes,
            totalBytes: totalBytes,
            bytesPerPixel: bytesPerPixel,
            bytesPerRow: bytesPerRow,
            imageWidth: width,
            imageHeight: height,
            outer: box.rect,
            glyphs: box.glyphRects
        ) {
            return palette
        }

        return Self.boxedLuminancePalette(
            bytes: bytes,
            totalBytes: totalBytes,
            bytesPerPixel: bytesPerPixel,
            bytesPerRow: bytesPerRow,
            imageWidth: width,
            imageHeight: height,
            originalBox: box.rect
        )
    }

    private static func glyphBoundedPalette(
        bytes: UnsafePointer<UInt8>,
        totalBytes: Int,
        bytesPerPixel: Int,
        bytesPerRow: Int,
        imageWidth: Int,
        imageHeight: Int,
        outer: CGRect,
        glyphs: [CGRect]
    ) -> ColorPalette? {
        var fgSamples: [(r: Int, g: Int, b: Int, lum: CGFloat)] = []
        var bgSamples: [(r: Int, g: Int, b: Int, lum: CGFloat)] = []

        // Foreground: sample pixels inside glyph rects (slightly inset).
        for glyph in glyphs {
            let inset = max(1, min(glyph.width, glyph.height) * 0.15)
            let inner = glyph.insetBy(dx: inset, dy: inset)
            let strideX = max(1, Int(inner.width / 4))
            let strideY = max(1, Int(inner.height / 3))
            var y = max(0, Int(inner.minY))
            let maxY = min(imageHeight - 1, Int(inner.maxY))
            let maxX = min(imageWidth - 1, Int(inner.maxX))
            while y <= maxY {
                var x = max(0, Int(inner.minX))
                while x <= maxX {
                    let offset = y * bytesPerRow + x * bytesPerPixel
                    if offset + 2 < totalBytes {
                        let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                        let lum = luminance(r: r, g: g, b: b)
                        fgSamples.append((r, g, b, lum))
                    }
                    x += strideX
                }
                y += strideY
            }
        }
        guard !fgSamples.isEmpty else { return nil }

        // Background: sample pixels inside `outer` that are NOT inside any glyph,
        // with a slight padding around each glyph so we skip anti-aliased edges.
        let pad: CGFloat = 1
        let strideX = max(1, Int(outer.width / 24))
        let strideY = max(1, Int(outer.height / 12))
        var y = max(0, Int(outer.minY))
        let maxY = min(imageHeight - 1, Int(outer.maxY))
        let maxX = min(imageWidth - 1, Int(outer.maxX))
        while y <= maxY {
            var x = max(0, Int(outer.minX))
            while x <= maxX {
                let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
                let insideGlyph = glyphs.contains { $0.insetBy(dx: -pad, dy: -pad).contains(point) }
                if !insideGlyph {
                    let offset = y * bytesPerRow + x * bytesPerPixel
                    if offset + 2 < totalBytes {
                        let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                        let lum = luminance(r: r, g: g, b: b)
                        bgSamples.append((r, g, b, lum))
                    }
                }
                x += strideX
            }
            y += strideY
        }
        guard !bgSamples.isEmpty else { return nil }

        let fg = average(fgSamples)
        let bg = average(bgSamples)
        // Sanity check: there must be enough contrast between the two clusters
        // to make this distinction meaningful.
        if abs(fg.lum - bg.lum) < 0.10 {
            return nil
        }
        return ColorPalette(foreground: fg.color, background: bg.color)
    }

    private static func boxedLuminancePalette(
        bytes: UnsafePointer<UInt8>,
        totalBytes: Int,
        bytesPerPixel: Int,
        bytesPerRow: Int,
        imageWidth: Int,
        imageHeight: Int,
        originalBox: CGRect
    ) -> ColorPalette {
        let inset = max(2, min(originalBox.width, originalBox.height) * 0.08)
        let sample = originalBox.insetBy(dx: inset, dy: inset)
        let minX = max(0, Int(sample.minX))
        let maxX = min(imageWidth - 1, Int(sample.maxX))
        let minY = max(0, Int(sample.minY))
        let maxY = min(imageHeight - 1, Int(sample.maxY))
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
                    let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
                    let lum = luminance(r: r, g: g, b: b)
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

        // Adaptive contrast threshold: use the larger of 0.10 (hard floor) and
        // 1.5× the per-box luminance standard deviation. Avoids the previous
        // fixed 0.18 cutoff misclassifying low-contrast-but-legible text as
        // "needs grayscale fallback".
        let meanLum = samples.reduce(0) { $0 + $1.lum } / CGFloat(samples.count)
        let variance = samples.reduce(0) { acc, s in
            let d = s.lum - meanLum
            return acc + d * d
        } / CGFloat(samples.count)
        let stdLum = sqrt(variance)
        let contrastThreshold = max(0.10, stdLum * 1.5)
        guard (maxLum - minLum) > contrastThreshold else {
            let avg = average(samples)
            return ColorPalette(foreground: avg.lum > 0.55 ? .black : .white, background: avg.color)
        }

        let midpoint = (minLum + maxLum) / 2
        let darkCluster = samples.filter { $0.lum <= midpoint }
        let brightCluster = samples.filter { $0.lum > midpoint }
        guard !darkCluster.isEmpty, !brightCluster.isEmpty else {
            let avg = average(samples)
            return ColorPalette(foreground: avg.lum > 0.55 ? .black : .white, background: avg.color)
        }

        let darkAvg = average(darkCluster)
        let brightAvg = average(brightCluster)
        if brightCluster.count >= darkCluster.count {
            return ColorPalette(foreground: darkAvg.color, background: brightAvg.color)
        } else {
            return ColorPalette(foreground: brightAvg.color, background: darkAvg.color)
        }
    }

    private static func luminance(r: Int, g: Int, b: Int) -> CGFloat {
        (0.2126 * CGFloat(r) + 0.7152 * CGFloat(g) + 0.0722 * CGFloat(b)) / 255
    }

    private static func average(_ samples: [(r: Int, g: Int, b: Int, lum: CGFloat)]) -> (color: UIColor, lum: CGFloat) {
        var rSum = 0, gSum = 0, bSum = 0
        var lSum: CGFloat = 0
        for s in samples {
            rSum += s.r; gSum += s.g; bSum += s.b; lSum += s.lum
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
