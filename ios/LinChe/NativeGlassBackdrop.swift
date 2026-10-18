import UIKit

/// A native timeline behind the transparent web shell. UIKit owns both the
/// text and material inside each cell; the website only sends content changes.
final class NativeGlassBackdrop: UIView, UITableViewDataSource, UITableViewDelegate {
    private let wallpaper = UIImageView()
    private let table = UITableView(frame: .zero, style: .plain)
    private let inputGlass = UIVisualEffectView()
    private let latestGlass = UIVisualEffectView()
    private let latestButton = UIButton(type: .system)
    private var rendererStorage: AnyObject?
    @available(iOS 26.0, *) private var renderer: NativeChatRenderer {
        if let value = rendererStorage as? NativeChatRenderer { return value }
        let value = NativeChatRenderer()
        value.action = { [weak self] id, kind, point in self?.onAction?(id, kind, point) }
        rendererStorage = value
        return value
    }
    var onAction: ((String, String, CGPoint) -> Void)?
    private(set) var generation: String?
    private var conversationID = ""
    private var savedOffsets: [String: CGFloat] = [:]
    private var desiredOrder: [String] = []
    private var desiredRows: [String: NativeChatRow] = [:]
    private var rows: [NativeChatRow] = []
    private var heights: [String: CGFloat] = [:]
    private var prepared = false
    private var blocked = false
    private var firstLayout = true
    private var pendingCommit = false
    private var pendingJump: String?
    private var changingLayout = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        wallpaper.contentMode = .scaleAspectFill
        wallpaper.clipsToBounds = true
        addSubview(wallpaper)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.estimatedRowHeight = 0
        table.estimatedSectionHeaderHeight = 0
        table.estimatedSectionFooterHeight = 0
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .none
        table.accessibilityIdentifier = "native-chat-list"
        addSubview(table)
        inputGlass.isUserInteractionEnabled = false
        addSubview(inputGlass)
        latestGlass.isUserInteractionEnabled = true
        latestGlass.accessibilityIdentifier = "native-latest-glass"
        latestButton.setImage(UIImage(systemName: "arrow.down"), for: .normal)
        latestButton.accessibilityIdentifier = "native-scroll-to-latest"
        latestButton.accessibilityLabel = "回到消息底部"
        latestButton.addTarget(self, action: #selector(returnToLatest), for: .touchUpInside)
        latestGlass.contentView.addSubview(latestButton)
        addSubview(latestGlass)
        accessibilityIdentifier = "native-glass-backdrop"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); wallpaper.frame = bounds }

    func acceptsTouch(_ point: CGPoint) -> Bool {
        !isHidden && !blocked && (table.frame.contains(point) || (!latestGlass.isHidden && latestGlass.frame.insetBy(dx: -5, dy: -5).contains(point)))
    }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !isHidden && !blocked && !latestGlass.isHidden && latestGlass.frame.insetBy(dx: -5, dy: -5).contains(point) { return latestButton }
        return super.hitTest(point, with: event)
    }

    func stop(generation expected: String? = nil) {
        if let expected, expected != generation { return }
        if !conversationID.isEmpty && !firstLayout { savedOffsets[conversationID] = table.contentOffset.y }
        generation = nil; prepared = false; firstLayout = true; pendingCommit = false; pendingJump = nil
        isHidden = true; wallpaper.image = nil
        desiredRows.removeAll(); desiredOrder.removeAll(); rows.removeAll(); heights.removeAll()
        table.reloadData()
        inputGlass.effect = nil; latestGlass.effect = nil
    }

    func prepare(_ body: [String: Any], completion: @escaping (Bool) -> Void) {
        guard let token = body["generation"] as? String,
              let background = body["background"] as? String, background.utf8.count <= 64 * 1024 * 1024 else {
            completion(false); return
        }
        stop()
        generation = token
        conversationID = body["conversationId"] as? String ?? ""
        let dark = body["appearance"] as? String == "dark"
        overrideUserInterfaceStyle = dark ? .dark : .light
        backgroundColor = dark ? UIColor(white: 11 / 255, alpha: 1)
            : UIColor(red: 245 / 255, green: 242 / 255, blue: 237 / 255, alpha: 1)
        if background.isEmpty { prepared = true; completion(true); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let parts = background.split(separator: ",", maxSplits: 1)
            let data = parts.count == 2 && parts[0].hasPrefix("data:image/") && parts[0].hasSuffix(";base64")
                ? Data(base64Encoded: String(parts[1])) : nil
            let image = data.flatMap { UIImage(data: $0)?.preparingForDisplay() }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.wallpaper.image = image; self.prepared = image != nil
                completion(image != nil)
            }
        }
    }

    @available(iOS 26.0, *)
    func apply(_ body: [String: Any]) -> Bool {
        guard prepared, body["generation"] as? String == generation,
              let width = body["width"] as? Double, width.isFinite, width > 0,
              let header = Self.rect(body["header"]), let composer = Self.rect(body["composer"]),
              let input = Self.rect(body["input"]), let order = body["order"] as? [String], order.count <= 10000,
              let updates = body["updates"] as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: updates),
              let decoded = try? JSONDecoder().decode([NativeChatRow].self, from: data) else { return false }
        let scale = bounds.width / CGFloat(width)
        guard scale.isFinite, scale > 0 else { return false }
        func scaled(_ rect: CGRect) -> CGRect { rect.applying(CGAffineTransform(scaleX: scale, y: scale)) }
        for row in decoded { desiredRows[row.id] = row }
        guard order.allSatisfy({ desiredRows[$0] != nil }) else { return false }
        desiredOrder = order
        let ids = Set(order)
        desiredRows = desiredRows.filter { ids.contains($0.key) }
        blocked = body["blocked"] as? Bool == true
        table.isUserInteractionEnabled = !blocked
        latestGlass.isUserInteractionEnabled = !blocked
        let follow = nearBottom
        let oldFrame = table.frame
        let oldWidth = table.bounds.width
        changingLayout = true
        let top = max(0, scaled(header).maxY)
        let bottom = max(top, scaled(composer).minY - 8)
        table.frame = CGRect(x: 0, y: top, width: bounds.width, height: bottom - top)
        // Keep the resting message clearance when the keyboard opens or the editor grows.
        table.contentInset.bottom = 36
        if oldWidth != table.bounds.width { heights.removeAll(); table.reloadData() }
        inputGlass.frame = scaled(input)
        if inputGlass.effect == nil { inputGlass.effect = UIGlassEffect(style: .regular) }
        inputGlass.cornerConfiguration = .corners(radius: .fixed(24))
        if latestGlass.effect == nil { latestGlass.effect = UIGlassEffect(style: .clear) }
        latestGlass.cornerConfiguration = .corners(radius: .fixed(17))
        latestGlass.frame = CGRect(x: scaled(composer).maxX - 46, y: bottom - 34, width: 34, height: 34)
        latestButton.frame = latestGlass.bounds
        if follow && !firstLayout && oldFrame != table.frame && !table.isDragging && !table.isDecelerating {
            table.layoutIfNeeded()
            scrollToBottom(animated: false)
        }
        changingLayout = false
        isHidden = false
        pendingCommit = true
        if !table.isDragging && !table.isDecelerating { commitRows() }
        updateLatest()
        return true
    }

    private var bottomOffset: CGFloat { max(-table.adjustedContentInset.top, table.contentSize.height + table.adjustedContentInset.bottom - table.bounds.height) }
    private var nearBottom: Bool { bottomOffset - table.contentOffset.y < 72 }
    private func scrollToBottom(animated: Bool) { table.setContentOffset(CGPoint(x: 0, y: bottomOffset), animated: animated) }
    @objc private func returnToLatest() { pendingJump = nil; scrollToBottom(animated: !UIAccessibility.isReduceMotionEnabled) }
    private func updateLatest() { latestGlass.isHidden = rows.isEmpty || nearBottom }

    private func commitRows() {
        guard pendingCommit else { return }
        pendingCommit = false
        let next = desiredOrder.compactMap { desiredRows[$0] }
        let follow = nearBottom
        let offset = table.contentOffset.y
        let anchorIndex = table.indexPathsForVisibleRows?.first
        let anchorID = anchorIndex.flatMap { $0.row < rows.count ? rows[$0.row].id : nil }
        let anchorDelta = anchorIndex.map { offset - table.rectForRow(at: $0).minY } ?? 0
        let changed = next.enumerated().compactMap { index, row in rows.indices.contains(index) && rows[index] == row ? nil : index }
        let sameOrder = rows.map(\.id) == next.map(\.id)
        let previous = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for row in next where previous[row.id] != row { heights.removeValue(forKey: row.id) }
        rows = next
        changingLayout = true
        UIView.performWithoutAnimation {
            if sameOrder && !changed.isEmpty {
                table.reloadRows(at: changed.map { IndexPath(row: $0, section: 0) }, with: .none)
            } else if !sameOrder { table.reloadData() }
            table.layoutIfNeeded()
            if firstLayout {
                if let saved = savedOffsets[conversationID] { table.contentOffset.y = min(bottomOffset, max(0, saved)) }
                else { scrollToBottom(animated: false) }
                firstLayout = false
            } else if follow { scrollToBottom(animated: false) }
            else if let id = anchorID, let index = rows.firstIndex(where: { $0.id == id }) {
                table.contentOffset.y = min(bottomOffset, max(0, table.rectForRow(at: IndexPath(row: index, section: 0)).minY + anchorDelta))
            } else { table.contentOffset.y = min(bottomOffset, max(0, offset)) }
        }
        changingLayout = false
        resolveJump()
        updateLatest()
    }

    func jump(to messageID: String) { pendingJump = messageID; resolveJump() }
    private func resolveJump() {
        guard let target = pendingJump, let index = rows.firstIndex(where: { $0.messageId == target }) else { return }
        pendingJump = nil
        table.scrollToRow(at: IndexPath(row: index, section: 0), at: .middle, animated: !UIAccessibility.isReduceMotionEnabled)
    }
    func numberOfSections(in tableView: UITableView) -> Int { 1 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let row = rows[indexPath.row]
        if let height = heights[row.id] { return height }
        guard #available(iOS 26.0, *) else { return 44 }
        let height = renderer.row(row, width: tableView.bounds.width).bounds.height
        heights[row.id] = height
        return height
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "message") ?? UITableViewCell(style: .default, reuseIdentifier: "message")
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.contentView.subviews.forEach { $0.removeFromSuperview() }
        if #available(iOS 26.0, *) { cell.contentView.addSubview(renderer.row(rows[indexPath.row], width: tableView.bounds.width)) }
        return cell
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !changingLayout else { return }
        updateLatest()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { commitRows() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { commitRows() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { updateLatest() }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let data = value as? [String: Any], let x = data["x"] as? Double, let y = data["y"] as? Double,
              let width = data["width"] as? Double, let height = data["height"] as? Double,
              [x, y, width, height].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }), width >= 0, height >= 0 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
