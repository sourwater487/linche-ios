import UIKit

/// Native playback of small, bundled pixel frames; no WebView or network assets.
final class ClawdLoadingView: UIView {
    static var backdrop: UIColor { UIColor(named: "LaunchBackground") ?? .systemBackground }
    var startedAt: CFTimeInterval = 0
    var isShowingFailure: Bool { outcome == .failure }
    private enum Outcome { case success, failure }
    private struct Animation: Decodable {
        let fps: Double
        let colors: [String]
        // Each block: center x/y, width/height, rotation degrees, palette, alpha.
        let clips: [String: [[[Double]]]]
    }
    private static let animation: Animation? = {
        guard let url = Bundle.main.url(forResource: "ClawdAnimation", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Animation.self, from: data)
    }()
    private static let palette: [UIColor] = (animation?.colors ?? []).map { hex in
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    private var displayLink: CADisplayLink?
    private var outcome: Outcome?
    private var outcomeAt: CFTimeInterval = 0
    private var now: CFTimeInterval = 0
    private var fading = false
    private var generation = 0
    private let stepDuration = 0.6
    private lazy var tickTarget = TickTarget(owner: self)

    private final class TickTarget: NSObject {
        weak var owner: ClawdLoadingView?
        init(owner: ClawdLoadingView) { self.owner = owner }
        @objc func tick() { owner?.tick() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.backdrop
        isHidden = true
        isAccessibilityElement = true
        accessibilityLabel = "Clawd 正在加载"
        accessibilityIdentifier = "clawd-loading"
        accessibilityTraits = .updatesFrequently
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { displayLink?.invalidate() }

    func startAnimating() {
        // Preserve the climb across redirects and the authentication hand-off.
        guard isHidden || outcome != nil else { return }
        generation += 1
        layer.removeAllAnimations()
        alpha = 1
        isHidden = false
        if outcome != nil { startedAt = 0 }
        outcome = nil
        fading = false
        accessibilityLabel = "Clawd 正在加载"
        if startedAt == 0 { startedAt = CACurrentMediaTime() }
        startClock()
        tick()
    }

    func stopAnimating() {
        generation += 1
        displayLink?.invalidate()
        displayLink = nil
        layer.removeAllAnimations()
        isHidden = true
        startedAt = 0
        outcome = nil
        fading = false
    }

    func finish() {
        guard !isHidden, outcome == nil else { return }
        settle(.success)
    }

    func fail() {
        guard outcome != .failure else { return }
        if isHidden { startAnimating() }
        // A late navigation failure must supersede an in-progress welcome.
        generation += 1
        layer.removeAllAnimations()
        fading = false
        alpha = 1
        settle(.failure)
    }

    private func settle(_ next: Outcome) {
        outcome = next
        let time = CACurrentMediaTime()
        outcomeAt = UIAccessibility.isReduceMotionEnabled ? time
            : startedAt + ceil((time - startedAt) / stepDuration) * stepDuration
        accessibilityLabel = next == .success ? "加载成功，Clawd 欢迎你回来" : "连接失败，可以重新连接"
        startClock()
        tick()
    }

    private func startClock() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: tickTarget, selector: #selector(TickTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func motionChanged() {
        guard !isHidden else { return }
        if outcome != nil && UIAccessibility.isReduceMotionEnabled { outcomeAt = CACurrentMediaTime() }
        startClock()
        tick()
    }

    private func tick() {
        now = CACurrentMediaTime()
        setNeedsDisplay()
        let reduced = UIAccessibility.isReduceMotionEnabled
        if outcome == .success && now >= outcomeAt + (reduced ? 0.25 : 1.3) && !fading {
            fading = true
            displayLink?.invalidate(); displayLink = nil
            let expected = generation
            UIView.animate(withDuration: reduced ? 0.12 : 0.18, animations: { self.alpha = 0 }) { [weak self] _ in
                guard let self, self.generation == expected else { return }
                self.stopAnimating()
            }
        } else if (outcome == .failure && now >= outcomeAt + (reduced ? 0 : 3)) || (reduced && outcome == nil) {
            // Hold the failed pose without burning CPU until the user retries.
            displayLink?.invalidate(); displayLink = nil
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        backgroundColor = Self.backdrop
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setShouldAntialias(false)
        let active = outcome != nil && now >= outcomeAt
        let clip = active ? (outcome == .success ? "success" : "failure") : "walk"
        let reduced = UIAccessibility.isReduceMotionEnabled
        let key = reduced ? "reduced" + clip.prefix(1).uppercased() + String(clip.dropFirst()) : clip
        guard let animation = Self.animation, let frames = animation.clips[key], !frames.isEmpty else {
            // Resource validation also checks the JSON; remain visible if it is missing.
            UIColor.secondaryLabel.setFill()
            context.fill(CGRect(x: bounds.midX - 12, y: bounds.midY - 3, width: 24, height: 6))
            return
        }
        let elapsed = max(0, now - (active ? outcomeAt : startedAt))
        let index = reduced ? 0 : clip == "walk" ? Int(elapsed * animation.fps) % frames.count
            : min(frames.count - 1, Int(elapsed * animation.fps))
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY - 25)
        for block in frames[index] where block.count == 7 {
            let color = Int(block[5])
            guard Self.palette.indices.contains(color) else { continue }
            context.saveGState()
            context.translateBy(x: CGFloat(block[0]), y: CGFloat(block[1]))
            context.rotate(by: CGFloat(block[4] * .pi / 180))
            context.setAlpha(CGFloat(block[6]))
            (color == 0 ? UIColor.secondaryLabel : Self.palette[color]).setFill()
            context.fill(CGRect(x: -block[2] / 2, y: -block[3] / 2, width: block[2], height: block[3]))
            context.restoreGState()
        }
        context.restoreGState()
    }
}
