import UIKit

enum ImageScaler {
    // 3200 px long-edge keeps modern phone screenshots (typically 1206×2622
    // or 1290×2796) at native resolution — Vision OCR's per-line bbox
    // accuracy drops sharply when small UI text gets pre-downsampled, and
    // the renderer's paragraph-merging heuristics rely on consistent bbox
    // proportions across an image. The earlier 1600 px cap silently halved
    // tall screenshots, producing visibly different (and worse) results on
    // device than the macOS render-preview tool that runs at full res.
    static let defaultMaxLongEdge: CGFloat = 3200

    static func downscale(_ image: UIImage, maxLongEdge: CGFloat = defaultMaxLongEdge) -> UIImage {
        let longEdge = max(image.size.width, image.size.height) * image.scale
        guard longEdge > maxLongEdge else { return image }

        let ratio = maxLongEdge / longEdge
        let targetSize = CGSize(
            width: image.size.width * image.scale * ratio,
            height: image.size.height * image.scale * ratio
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
