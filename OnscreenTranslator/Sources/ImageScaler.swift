import UIKit

enum ImageScaler {
    static let defaultMaxLongEdge: CGFloat = 1600

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
