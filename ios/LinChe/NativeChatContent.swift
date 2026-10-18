import UIKit
import ImageIO

struct NativeChatRun: Decodable, Equatable {
    let text: String
    let size: Double?
    let bold: Bool?
    let italic: Bool?
    let mono: Bool?
    let strike: Bool?
    let color: [Double]?
    let action: String?
}
struct NativeChatNode: Decodable, Equatable {
    let kind: String
    let runs: [NativeChatRun]?
    let children: [NativeChatNode]?
    let horizontal: Bool?
    let label: String?
    let action: String?
    let disabled: Bool?
    let source: String?
    let aspect: Double?
    let avatar: Bool?
    let reaction: String?
    let align: String?
    let justify: String?
    let gap: Double?
    let icon: String?
    let color: [Double]?
    let mediaWidth: Double?
    let mediaHeight: Double?
}
struct NativeChatRow: Decodable, Equatable {
    let id: String
    let outgoing: Bool
    let nodes: [NativeChatNode]
    let messageId: String?
}

private final class NativeReactionTap: UITapGestureRecognizer {
    var actionID = ""
}

/// Text and material are children of the same view. Neither is positioned from
/// a WebView rectangle, so scrolling and text reflow cannot separate them.
@available(iOS 26.0, *)
final class NativeChatRenderer: NSObject, UITextViewDelegate {
    var action: ((String, String, CGPoint) -> Void)?
    private let images = NSCache<NSString, UIImage>()

    override init() {
        super.init()
        images.totalCostLimit = 32 * 1024 * 1024
    }

    private func naturalWidth(_ nodes: [NativeChatNode], limit: CGFloat) -> CGFloat {
        nodes.map { node -> CGFloat in
            if let runs = node.runs {
                let text = runs.map(\.text).joined() as NSString
                let size = CGFloat(runs.compactMap(\.size).max() ?? 14)
                return ceil(text.boundingRect(with: CGSize(width: limit, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NativeTypography.font(size: size)], context: nil).width) + 4
            }
            if node.kind == "button" { return node.icon != nil ? 24 : min(limit, CGFloat((node.label ?? "").count) * 12 + 12) }
            if node.kind == "image" { return min(limit, CGFloat(node.mediaWidth ?? 150)) }
            if let children = node.children {
                if node.horizontal == true {
                    return min(limit, children.reduce(CGFloat(0)) { $0 + naturalWidth([$1], limit: limit) }
                        + CGFloat(max(0, children.count - 1)) * CGFloat(node.gap ?? 8))
                }
                return naturalWidth(children, limit: limit)
            }
            return limit
        }.max() ?? limit
    }

    private func emit(_ id: String, kind: String = "click", view: UIView) {
        action?(id, kind, view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
    }

    func row(_ row: NativeChatRow, width: CGFloat) -> UIView {
        let content = group(row.nodes, width: max(1, width - 32), outgoing: row.outgoing)
        content.frame.origin = CGPoint(x: row.outgoing ? width - content.frame.width - 16 : 16, y: 8)
        let root = UIView(frame: CGRect(x: 0, y: 0, width: width, height: content.frame.maxY + 18))
        root.accessibilityIdentifier = "native-message-\(row.messageId ?? row.id)"
        root.addSubview(content)
        return root
    }

    private func group(_ children: [NativeChatNode], width: CGFloat, outgoing: Bool, horizontal: Bool = false,
                       justify: String? = nil, gap: CGFloat = 8) -> UIView {
        let root = UIView()
        let available = max(1, width - CGFloat(max(0, children.count - 1)) * gap)
        let desired = children.map { naturalWidth([$0], limit: available) }
        let total = max(1, desired.reduce(0, +))
        let views = children.enumerated().map { index, child in
            render(child, width: horizontal ? max(1, desired[index] * min(1, available / total)) : width, outgoing: outgoing)
        }.filter { $0.bounds.height > 0 }
        let occupied = views.reduce(CGFloat(0)) { $0 + $1.bounds.width } + CGFloat(max(0, views.count - 1)) * gap
        let spacing = horizontal && justify == "space-between" && views.count > 1
            ? gap + max(0, width - occupied) / CGFloat(views.count - 1) : gap
        var cursor: CGFloat = horizontal && (justify == "flex-end" || justify == "end") ? max(0, width - occupied)
            : horizontal && justify == "center" ? max(0, (width - occupied) / 2) : 0
        let maxHeight = views.map { $0.bounds.height }.max() ?? 0
        for view in views {
            view.frame.origin = horizontal ? CGPoint(x: cursor, y: (maxHeight - view.bounds.height) / 2)
                : CGPoint(x: outgoing ? width - view.bounds.width : 0, y: cursor)
            root.addSubview(view)
            cursor += (horizontal ? view.bounds.width : view.bounds.height) + spacing
        }
        root.frame = CGRect(x: 0, y: 0, width: width, height: horizontal ? maxHeight : max(0, cursor - spacing))
        return root
    }

    private func render(_ node: NativeChatNode, width: CGFloat, outgoing: Bool) -> UIView {
        switch node.kind {
        case "glass":
            let limit = max(1, width * 0.9 - 24)
            let glassWidth = min(width, max(64, min(limit, naturalWidth(node.children ?? [], limit: limit)) + 24))
            let child = group(node.children ?? [], width: max(1, glassWidth - 24), outgoing: false)
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = false
            let glass = UIVisualEffectView(effect: effect)
            glass.accessibilityIdentifier = "native-message-glass"
            glass.cornerConfiguration = .corners(radius: .fixed(18))
            glass.frame = CGRect(x: 0, y: 0, width: glassWidth, height: child.bounds.height + 20)
            child.frame.origin = CGPoint(x: 12, y: 10)
            glass.contentView.addSubview(child)
            if let id = node.reaction {
                let tap = NativeReactionTap(target: self, action: #selector(reaction(_:)))
                tap.actionID = id
                tap.numberOfTapsRequired = 2
                tap.cancelsTouchesInView = false
                glass.addGestureRecognizer(tap)
            }
            return glass
        case "group":
            return group(node.children ?? [], width: width, outgoing: outgoing, horizontal: node.horizontal == true, justify: node.justify, gap: CGFloat(node.gap ?? 8))
        case "button":
            let button = UIButton(type: .system)
            if let icon = node.icon {
                button.setImage(UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)), for: .normal)
            } else { button.setTitle(node.label ?? "打开", for: .normal) }
            button.tintColor = .label
            if let c = node.color, c.count >= 3 {
                button.tintColor = UIColor(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: c.count > 3 ? c[3] : 1)
            }
            button.titleLabel?.font = NativeTypography.font(size: 12)
            button.titleLabel?.numberOfLines = 0
            button.isEnabled = node.disabled != true
            button.accessibilityLabel = node.label
            let size = button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            button.frame = CGRect(x: 0, y: 0, width: min(width, node.icon != nil ? 24 : max(24, size.width + 4)), height: max(24, size.height))
            if let id = node.action {
                button.addAction(UIAction { [weak self, weak button] _ in
                    guard let button else { return }; self?.emit(id, view: button)
                }, for: .touchUpInside)
            }
            return button
        case "image":
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.accessibilityLabel = node.label
            imageView.isAccessibilityElement = true
            let source = node.source ?? ""
            if let cached = images.object(forKey: source as NSString) { imageView.image = cached }
            else if source.hasPrefix("data:image/"), let separator = source.firstIndex(of: ","),
                    let data = Data(base64Encoded: String(source[source.index(after: separator)...])),
                    let sourceImage = CGImageSourceCreateWithData(data as CFData, nil),
                    let thumbnail = CGImageSourceCreateThumbnailAtIndex(sourceImage, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 900
                    ] as CFDictionary) {
                let image = UIImage(cgImage: thumbnail)
                images.setObject(image, forKey: source as NSString, cost: thumbnail.bytesPerRow * thumbnail.height)
                imageView.image = image
            }
            let aspect = max(0.1, min(20, node.aspect ?? 1))
            let w = min(width, CGFloat(node.mediaWidth ?? (node.avatar == true ? 50 : 260)))
            let h = CGFloat(node.mediaHeight ?? Double(w / aspect))
            let ratio = min(1, w / max(1, CGFloat(node.mediaWidth ?? Double(w))))
            imageView.frame = CGRect(x: 0, y: 0, width: w, height: max(1, h * ratio))
            imageView.layer.cornerRadius = 10
            let button = UIButton(type: .custom)
            button.frame = imageView.frame
            button.addSubview(imageView)
            button.accessibilityLabel = node.label ?? "查看图片"
            if let id = node.action {
                button.addAction(UIAction { [weak self, weak button] _ in
                    guard let button else { return }; self?.emit(id, view: button)
                }, for: .touchUpInside)
            }
            return button
        default:
            let text = UITextView()
            text.backgroundColor = .clear
            text.isEditable = false
            text.isSelectable = true
            text.isScrollEnabled = false
            text.textContainerInset = .zero
            text.textContainer.lineFragmentPadding = 0
            text.delegate = self
            let result = NSMutableAttributedString(string: "")
            for run in node.runs ?? [] {
                let size = CGFloat(max(10, min(24, run.size ?? 14)))
                var font = run.mono == true ? UIFont.monospacedSystemFont(ofSize: size, weight: run.bold == true ? .semibold : .regular)
                    : NativeTypography.font(size: size, bold: run.bold == true)
                if run.italic == true, let descriptor = font.fontDescriptor.withSymbolicTraits([font.fontDescriptor.symbolicTraits, .traitItalic]) {
                    font = UIFont(descriptor: descriptor, size: size)
                }
                var color = UIColor.label
                if let c = run.color, c.count >= 3 {
                    color = UIColor(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: c.count > 3 ? c[3] : 1)
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 4
                paragraph.alignment = node.align == "center" ? .center : ["right", "end"].contains(node.align ?? "") ? .right : .left
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
                if run.strike == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let id = run.action { attributes[.link] = "linche-action://\(id)" }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            text.attributedText = result
            let height = ceil(text.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            text.frame = CGRect(x: 0, y: 0, width: width, height: max(1, height))
            text.accessibilityIdentifier = "native-message-text"
            return text
        }
    }

    @objc private func reaction(_ recognizer: NativeReactionTap) {
        guard let view = recognizer.view else { return }
        emit(recognizer.actionID, kind: "reaction", view: view)
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        if URL.scheme == "linche-action", let id = URL.host { emit(id, view: textView) }
        return false
    }
}
