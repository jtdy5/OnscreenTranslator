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

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))

            for (box, translation) in zip(boxes, translations) {
                let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != box.text else { continue }

                let base = box.rect.insetBy(dx: -6, dy: -4)
                let canvas = CGRect(origin: .zero, size: size)
                let padded = expandedRect(
                    base: base,
                    for: trimmed,
                    minFontSize: 9,
                    canvas: canvas
                )
                let background = sampledColor(from: cgImage, around: padded).withAlphaComponent(maskOpacity)
                let path = UIBezierPath(roundedRect: padded, cornerRadius: min(8, padded.height / 4))
                background.setFill()
                path.fill()

                draw(trimmed, in: padded.insetBy(dx: 4, dy: 2), context: context.cgContext, background: background)
            }
        }
    }

    private func expandedRect(base: CGRect, for text: String, minFontSize: CGFloat, canvas: CGRect) -> CGRect {
        let targetFontSize = max(minFontSize, min(40, base.height * 0.75))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: targetFontSize, weight: .semibold)
        ]
        let measured = text.boundingRect(
            with: CGSize(width: .greatestFiniteMagnitude, height: base.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        let needed = measured.width + 16
        guard needed > base.width else {
            return base.intersection(canvas)
        }
        let target = min(needed, base.width * 3.0)
        let extra = max(0, target - base.width)
        let leftRoom = base.minX - canvas.minX
        let rightRoom = canvas.maxX - base.maxX
        let leftGrow = min(extra / 2, leftRoom)
        let rightGrow = min(extra - leftGrow, rightRoom)
        let finalLeft = min(extra - rightGrow, leftRoom)
        let expanded = CGRect(
            x: base.minX - finalLeft,
            y: base.minY,
            width: base.width + finalLeft + rightGrow,
            height: base.height
        )
        return expanded.intersection(canvas)
    }

    private func draw(_ text: String, in rect: CGRect, context: CGContext, background: UIColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        var fontSize = max(11, min(40, rect.height * 0.75))
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: background.readableForegroundColor,
            .paragraphStyle: paragraph
        ]

        while fontSize > 10 {
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

        let measured = text.boundingRect(
            with: rect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        let drawRect = CGRect(
            x: rect.minX,
            y: rect.minY + max(0, (rect.height - measured.height) / 2),
            width: rect.width,
            height: rect.height
        )
        text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
    }

    private func sampledColor(from image: CGImage, around rect: CGRect) -> UIColor {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return UIColor.white
        }

        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let bytesPerRow = image.bytesPerRow
        let width = image.width
        let height = image.height

        let samplePoints = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.midY)
        ]

        var red = 0
        var green = 0
        var blue = 0
        var count = 0

        for point in samplePoints {
            let x = min(max(Int(point.x), 0), width - 1)
            let y = min(max(Int(point.y), 0), height - 1)
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 2 < CFDataGetLength(data) else { continue }
            red += Int(bytes[offset])
            green += Int(bytes[offset + 1])
            blue += Int(bytes[offset + 2])
            count += 1
        }

        guard count > 0 else {
            return UIColor.white
        }

        let color = UIColor(
            red: CGFloat(red / count) / 255,
            green: CGFloat(green / count) / 255,
            blue: CGFloat(blue / count) / 255,
            alpha: 1
        )
        return color.isReadableBackground ? color : UIColor.white
    }
}

private extension UIColor {
    var isReadableBackground: Bool {
        luminance > 0.18 && luminance < 0.92
    }

    var readableForegroundColor: UIColor {
        luminance > 0.55 ? .black : .white
    }

    var luminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
