import UIKit
import ImageIO
import CoreText

struct NativeChatRun: Decodable, Equatable {
    let text: String
    let size: Double?
    let lineHeight: Double?
    let bold: Bool?
    let italic: Bool?
    let mono: Bool?
    let strike: Bool?
    let color: [Double]?
    let action: String?
}
struct NativeBadgeGlyph: Decodable, Equatable { let text: String; let x: Double; let y: Double; let width: Double; let height: Double }
struct NativeWaveBar: Decodable, Equatable { let height: Double; let color: [Double] }
struct NativeChatBox: Decodable, Equatable {
    let width: Double
    let height: Double?
    let margin: [Double]
    let padding: [Double]
    let alignSelf: String
    let alignItems: String
    let radius: Double
    let borderWidth: Double?
    let borderColor: [Double]?
}
struct NativeChatNode: Decodable, Equatable {
    let box: NativeChatBox?
    let footerText: Bool?
    let anchorKeys: [String]?
    let anchor: String?
    let spaceBefore: Double?
    let glyphs: [NativeBadgeGlyph]?
    let iconSource: String?
    let iconSize: Double?
    let title: String?
    let fontSize: Double?
    let bars: [NativeWaveBar]?
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
    let centered: Bool?
    let inset: Double?
    let spacing: Double?
}

/// Footer metadata is a single line. Center its visible glyphs in the same
/// 24pt row as the SVG controls, independently of the font's ascent/descent.
private final class NativeFooterText: UIView {
    let line: CTLine
    init(text: NSAttributedString, width: CGFloat) {
        line = CTLineCreateWithAttributedString(text as CFAttributedString)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 24))
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = true
        accessibilityLabel = text.string
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard !ink.isNull else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: max(0, -ink.minX), y: bounds.midY + ink.midY)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

private final class NativeReactionTap: UITapGestureRecognizer {
    var actionID = ""
}

/// Text and material are children of the same view. Neither is positioned from
/// a WebView rectangle, so scrolling and text reflow cannot separate them.
@available(iOS 26.0, *)
final class NativeChatRenderer: NSObject, UITextViewDelegate {
    var action: ((String, String, CGPoint) -> Void)?
    private var anchors: [String: UIView] = [:]
    private let images = NSCache<NSString, UIImage>()

    override init() {
        super.init()
        images.totalCostLimit = 32 * 1024 * 1024
    }

    private func naturalWidth(_ nodes: [NativeChatNode], limit: CGFloat) -> CGFloat {
        nodes.map { node -> CGFloat in
            if let box = node.box { return min(limit, CGFloat(box.width)) }
            if let runs = node.runs {
                let text = runs.map(\.text).joined() as NSString
                let size = CGFloat(runs.compactMap(\.size).max() ?? 14)
                return ceil(text.boundingRect(with: CGSize(width: limit, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NativeTypography.font(size: size)], context: nil).width) + 4
            }
            if node.kind == "button" { return min(limit, (node.icon != nil ? CGFloat(node.iconSize ?? 14) + 8 : 0) + CGFloat((node.title ?? node.label ?? "").count) * CGFloat(node.fontSize ?? 12) + 8) }
            if node.kind == "waveform" { return min(limit, 170) }
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

    func row(_ row: NativeChatRow, width: CGFloat, minimumHeight: CGFloat = 0) -> UIView {
        anchors.removeAll()
        let inset = CGFloat(row.inset ?? 22)
        let content = group(row.nodes, width: max(1, width - inset * 2), outgoing: row.outgoing)
        content.frame.origin = CGPoint(x: inset, y: 0)
        let root = UIView(frame: CGRect(x: 0, y: 0, width: width, height: content.frame.maxY + CGFloat(row.spacing ?? 28)))
        if row.centered == true {
            root.frame.size.height = max(root.frame.height, minimumHeight)
            content.frame.origin.y = max(8, (root.bounds.height - content.bounds.height) / 2)
        }
        root.accessibilityIdentifier = "native-message-\(row.messageId ?? row.id)"
        root.addSubview(content)
        func addBadges(_ nodes: [NativeChatNode]) {
            for node in nodes {
                if node.kind == "badge", let key = node.anchor, let anchor = anchors[key] {
                    let rect = anchor.convert(anchor.bounds, to: root)
                    let width = min(root.bounds.width - 32, CGFloat(node.mediaWidth ?? 34))
                    let height = CGFloat(node.mediaHeight ?? 42)
                    let button = UIButton(type: .custom)
                    let x = node.align == "left" ? rect.minX : rect.maxX - width
                    button.frame = CGRect(x: max(16, min(root.bounds.width - width - 16, x)), y: max(0, rect.minY - height + 5), width: width, height: height)
                    if let image = NativeArtwork.image(node.source, size: width, height: height) { button.setBackgroundImage(image, for: .normal) }
                    button.accessibilityLabel = node.label
                    for glyph in node.glyphs ?? [] {
                        let label = UILabel(frame: CGRect(x: glyph.x, y: glyph.y, width: glyph.width, height: glyph.height))
                        label.text = glyph.text; label.font = NativeTypography.font(size: 16); label.textColor = Self.color(node.color)
                        label.textAlignment = .center; button.addSubview(label)
                    }
                    if let id = node.action { button.addAction(UIAction { [weak self, weak button] _ in
                        guard let button else { return }; self?.emit(id, view: button)
                    }, for: .touchUpInside) }
                    root.addSubview(button)
                }
                addBadges(node.children ?? [])
            }
        }
        addBadges(row.nodes)
        return root
    }

    private func group(_ children: [NativeChatNode], width: CGFloat, outgoing: Bool, horizontal: Bool = false,
                       justify: String? = nil, gap: CGFloat = 0, alignItems: String? = nil) -> UIView {
        let root = UIView()
        let children = children.filter { $0.kind != "badge" }
        let margins = children.map { ($0.box?.margin ?? [0, 0, 0, 0]).map { CGFloat($0) } }
        let available = max(1, width - CGFloat(max(0, children.count - 1)) * gap
            - (horizontal ? margins.reduce(0) { $0 + $1[1] + $1[3] } : 0))
        let desired = children.map { naturalWidth([$0], limit: available) }
        let total = max(1, desired.reduce(0, +))
        let views = children.enumerated().map { index, child in
            render(child, width: horizontal ? max(1, desired[index] * min(1, available / total))
                : max(1, width - margins[index][1] - margins[index][3]), outgoing: outgoing)
        }
        let occupied = views.enumerated().reduce(CGFloat(0)) { $0 + $1.element.bounds.width + margins[$1.offset][1] + margins[$1.offset][3] }
            + CGFloat(max(0, views.count - 1)) * gap
        let spacing = horizontal && justify == "space-between" && views.count > 1
            ? gap + max(0, width - occupied) / CGFloat(views.count - 1) : gap
        var cursor: CGFloat = horizontal && ["flex-end", "end"].contains(justify ?? "") ? max(0, width - occupied)
            : horizontal && justify == "center" ? max(0, (width - occupied) / 2) : 0
        let maxHeight = views.enumerated().map { $0.element.bounds.height + margins[$0.offset][0] + margins[$0.offset][2] }.max() ?? 0
        for (index, view) in views.enumerated() {
            let margin = margins[index]
            let alignment = children[index].box?.alignSelf ?? alignItems ?? (outgoing ? "flex-end" : "flex-start")
            if horizontal {
                cursor += margin[3]
                let free = max(0, maxHeight - view.bounds.height - margin[0] - margin[2])
                let y = margin[0] + (["flex-end", "end"].contains(alignment) ? free : alignment == "center" ? free / 2 : 0)
                view.frame.origin = CGPoint(x: cursor, y: y)
                cursor += view.bounds.width + margin[1] + spacing
            } else {
                cursor += margin[0] + CGFloat(children[index].spaceBefore ?? 0)
                let free = max(0, width - view.bounds.width - margin[1] - margin[3])
                let x = margin[3] + (["flex-end", "end"].contains(alignment) ? free : alignment == "center" ? free / 2 : 0)
                view.frame.origin = CGPoint(x: x, y: cursor)
                cursor += view.bounds.height + margin[2] + spacing
            }
            root.addSubview(view)
        }
        root.frame = CGRect(x: 0, y: 0, width: width, height: horizontal ? maxHeight : max(0, cursor - spacing))
        return root
    }

    private func render(_ node: NativeChatNode, width: CGFloat, outgoing: Bool) -> UIView {
        let constrained = max(1, min(width, CGFloat(node.box?.width ?? Double(width))))
        let view = renderContent(node, width: constrained, outgoing: outgoing)
        if let box = node.box, let border = box.borderWidth, border > 0 {
            view.layer.borderWidth = CGFloat(border)
            view.layer.borderColor = Self.color(box.borderColor).cgColor
            view.layer.cornerRadius = CGFloat(box.radius)
            view.clipsToBounds = true
        }
        for key in node.anchorKeys ?? [] { anchors[key] = view }
        return view
    }

    private func renderContent(_ node: NativeChatNode, width: CGFloat, outgoing: Bool) -> UIView {
        switch node.kind {
        case "badge": return UIView()
        case "glass":
            let padding = (node.box?.padding ?? [10, 12, 10, 12]).map { CGFloat($0) }
            let glassWidth = width
            let child = group(node.children ?? [], width: max(1, width - padding[1] - padding[3]), outgoing: false,
                horizontal: node.horizontal == true, justify: node.justify, gap: CGFloat(node.gap ?? 0))
            let effect = UIGlassEffect(style: .regular)
            effect.isInteractive = false
            let glass = UIVisualEffectView(effect: effect)
            glass.accessibilityIdentifier = "native-message-glass"
            glass.cornerConfiguration = .corners(radius: .fixed(CGFloat(node.box?.radius ?? 18)))
            glass.frame = CGRect(x: 0, y: 0, width: glassWidth, height: child.bounds.height + padding[0] + padding[2])
            child.frame.origin = CGPoint(x: padding[3], y: padding[0])
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
            let padding = (node.box?.padding ?? [0, 0, 0, 0]).map { CGFloat($0) }
            let content = group(node.children ?? [], width: max(1, width - padding[1] - padding[3]), outgoing: outgoing,
                horizontal: node.horizontal == true, justify: node.justify, gap: CGFloat(node.gap ?? 0), alignItems: node.box?.alignItems)
            let root = UIView(frame: CGRect(x: 0, y: 0, width: width,
                height: max(CGFloat(node.box?.height ?? 0), content.bounds.height + padding[0] + padding[2])))
            content.frame.origin = CGPoint(x: padding[3], y: padding[0]); root.addSubview(content)
            return root
        case "button":
            let button = UIButton(type: .system)
            if let image = NativeArtwork.image(node.iconSource, size: CGFloat(node.iconSize ?? 14)) {
                button.setImage(image, for: .normal)
            }
            button.setTitle(node.title ?? (node.icon == nil ? node.label : nil), for: .normal)
            button.tintColor = .label
            if let c = node.color, c.count >= 3 {
                button.tintColor = UIColor(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: c.count > 3 ? c[3] : 1)
            }
            button.setTitleColor(button.tintColor, for: .normal)
            button.titleLabel?.font = NativeTypography.font(size: CGFloat(node.fontSize ?? 12))
            button.titleLabel?.numberOfLines = 0
            button.isEnabled = node.disabled != true
            button.accessibilityLabel = node.label
            let size = button.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            button.frame = CGRect(x: 0, y: 0, width: width, height: CGFloat(node.box?.height ?? Double(max(24, size.height))))
            if let id = node.action {
                button.addAction(UIAction { [weak self, weak button] _ in
                    guard let button else { return }; self?.emit(id, view: button)
                }, for: .touchUpInside)
            }
            return button
        case "waveform":
            let button = UIButton(type: .custom)
            button.frame = CGRect(x: 0, y: 0, width: min(width, 170), height: 32)
            button.accessibilityLabel = node.label
            button.isEnabled = node.disabled != true
            let label = UILabel(); label.text = node.title; label.font = NativeTypography.font(size: CGFloat(node.fontSize ?? 13))
            label.textColor = Self.color(node.color)
            label.frame = CGRect(x: max(0, button.bounds.width - 38), y: 0, width: 38, height: 32)
            label.textAlignment = .right; button.addSubview(label)
            let bars = node.bars ?? []
            let step = max(1, (button.bounds.width - 46) / CGFloat(max(1, bars.count)))
            for (index, bar) in bars.enumerated() {
                let height = max(2, min(21, CGFloat(bar.height) * 21))
                let view = UIView(frame: CGRect(x: CGFloat(index) * step, y: (32 - height) / 2, width: max(1, step - 2), height: height))
                view.backgroundColor = Self.color(bar.color); view.layer.cornerRadius = 1
                view.isUserInteractionEnabled = false; button.addSubview(view)
            }
            if let id = node.action { button.addAction(UIAction { [weak self, weak button] _ in
                guard let button else { return }; self?.emit(id, view: button)
            }, for: .touchUpInside) }
            return button
        case "image":
            let imageView = UIImageView()
            imageView.contentMode = node.avatar == true ? .scaleAspectFill : .scaleAspectFit
            imageView.clipsToBounds = true
            imageView.accessibilityLabel = node.label
            imageView.isAccessibilityElement = true
            let source = node.source ?? ""
            if let cached = images.object(forKey: source as NSString) { imageView.image = cached }
            else if source.hasPrefix("data:image/"), let separator = source.firstIndex(of: ","),
                    let data = Data(base64Encoded: String(source[source.index(after: separator)...])),
                    let sourceImage = CGImageSourceCreateWithData(data as CFData, nil) {
                let count = CGImageSourceGetCount(sourceImage)
                // Keep animated stickers moving. Bound decoded pixels, not the
                // number of animation frames, so long GIFs retain their content.
                let pixelSize = count > 1 ? min(450, max(64, Int(sqrt(8_000_000.0 / Double(count))))) : 900
                var frames: [UIImage] = []
                var delays: [Int] = []
                var cost = 0
                for index in 0..<count {
                    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(sourceImage, index, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: pixelSize
                    ] as CFDictionary) else { continue }
                    frames.append(UIImage(cgImage: thumbnail)); cost += thumbnail.bytesPerRow * thumbnail.height
                    let properties = CGImageSourceCopyPropertiesAtIndex(sourceImage, index, nil) as? [CFString: Any]
                    let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                        ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
                    delays.append(max(2, Int((delay * 100).rounded())))
                }
                if let first = frames.first {
                    func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
                    let quantum = max(2, delays.reduce(delays.first ?? 10) { gcd($0, $1) })
                    let animation = zip(frames, delays).flatMap { frame, delay in Array(repeating: frame, count: max(1, delay / quantum)) }
                    let image = frames.count > 1 ? UIImage.animatedImage(with: animation, duration: Double(delays.reduce(0, +)) / 100) ?? first : first
                    images.setObject(image, forKey: source as NSString, cost: cost)
                    imageView.image = image
                }
            }
            let aspect = max(0.1, min(20, node.aspect ?? 1))
            let w = min(width, CGFloat(node.mediaWidth ?? (node.avatar == true ? 50 : 260)))
            let h = CGFloat(node.mediaHeight ?? Double(w / aspect))
            let ratio = min(1, w / max(1, CGFloat(node.mediaWidth ?? Double(w))))
            imageView.frame = CGRect(x: 0, y: 0, width: w, height: max(1, h * ratio))
            imageView.layer.cornerRadius = CGFloat(node.box?.radius ?? 0)
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
            text.tintColor = .label
            text.linkTextAttributes = [:] // Preserve each run's CSS link color, not UIKit blue.
            let result = NSMutableAttributedString(string: "")
            for run in node.runs ?? [] {
                let size = CGFloat(max(10, min(64, run.size ?? 14)))
                let font = run.mono == true ? UIFont.monospacedSystemFont(ofSize: size, weight: run.bold == true ? .semibold : .regular)
                    : NativeTypography.font(size: size, bold: run.bold == true, italic: run.italic == true)
                var color = UIColor.label
                if let c = run.color, c.count >= 3 {
                    color = UIColor(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: c.count > 3 ? c[3] : 1)
                }
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = max(0, CGFloat(run.lineHeight ?? Double(font.lineHeight + 4)) - font.lineHeight)
                paragraph.alignment = node.align == "center" ? .center : ["right", "end"].contains(node.align ?? "") ? .right : .left
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
                if run.italic == true && run.mono == true { attributes[.obliqueness] = 0.18 }
                if run.strike == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let id = run.action { attributes[.link] = "linche-action://\(id)" }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            if node.footerText == true {
                return NativeFooterText(text: result, width: width)
            }
            text.attributedText = result
            let height = ceil(text.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            text.frame = CGRect(x: 0, y: 0, width: width, height: max(1, height))
            text.accessibilityIdentifier = "native-message-text"
            return text
        }
    }

    private static func color(_ values: [Double]?) -> UIColor {
        guard let c = values, c.count >= 3 else { return .label }
        return UIColor(red: c[0] / 255, green: c[1] / 255, blue: c[2] / 255, alpha: c.count > 3 ? c[3] : 1)
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
