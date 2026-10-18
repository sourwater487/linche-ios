import UIKit

enum NativeArtwork {
    static func image(_ value: String?, size: CGFloat = 18, height: CGFloat? = nil) -> UIImage? {
        guard let value, value.hasPrefix("data:image/png;base64,"),
              let data = Data(base64Encoded: String(value.dropFirst(22))), let source = UIImage(data: data) else { return nil }
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: height ?? size)).image { _ in
            source.draw(in: CGRect(x: 0, y: 0, width: size, height: height ?? size))
        }.withRenderingMode(.alwaysOriginal)
    }

    // Exact path from ChatPage's scroll-to-latest SVG: M12 5v14m-6-6 6 6 6-6.
    static let latest: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 17, height: 17)).image { context in
        context.cgContext.scaleBy(x: 17.0 / 24.0, y: 17.0 / 24.0)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 12, y: 5)); path.addLine(to: CGPoint(x: 12, y: 19))
        path.move(to: CGPoint(x: 6, y: 13)); path.addLine(to: CGPoint(x: 12, y: 19)); path.addLine(to: CGPoint(x: 18, y: 13))
        path.lineWidth = 1.5; path.lineCapStyle = .round; path.lineJoinStyle = .round
        UIColor.black.setStroke(); path.stroke()
    }.withRenderingMode(.alwaysTemplate)
}
