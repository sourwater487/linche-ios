import UIKit

/// A small, native pixel animation. It never depends on the web page or network.
final class ClawdLoadingView: UIView {
    static var backdrop: UIColor { UIColor(named: "LaunchBackground") ?? .systemBackground }
    var startedAt: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var finishAt: CFTimeInterval?
    private var elapsed: Double = 0
    private let stepDuration = 0.55
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
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { displayLink?.invalidate() }

    func startAnimating() {
        guard isHidden else { return }
        layer.removeAllAnimations()
        alpha = 1
        isHidden = false
        finishAt = nil
        if startedAt == 0 { startedAt = CACurrentMediaTime() }
        let link = CADisplayLink(target: tickTarget, selector: #selector(TickTarget.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        tick()
    }

    func stopAnimating() {
        displayLink?.invalidate()
        displayLink = nil
        isHidden = true
        startedAt = 0
        finishAt = nil
    }

    func finish() {
        guard !isHidden, finishAt == nil else { return }
        // Land on the next step, then give one small welcoming bounce.
        let now = CACurrentMediaTime()
        finishAt = UIAccessibility.isReduceMotionEnabled ? now : startedAt + ceil((now - startedAt) / stepDuration) * stepDuration
    }

    private func tick() {
        let now = CACurrentMediaTime()
        elapsed = max(0, now - startedAt)
        setNeedsDisplay()
        if let end = finishAt, now >= end + (UIAccessibility.isReduceMotionEnabled ? 0 : 0.32) {
            displayLink?.invalidate()
            displayLink = nil
            UIView.animate(withDuration: 0.18, animations: { self.alpha = 0 }) { _ in self.stopAnimating() }
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
        let reduced = UIAccessibility.isReduceMotionEnabled
        let celebrating = finishAt.map { CACurrentMediaTime() >= $0 } ?? false
        let phase = reduced || celebrating ? 0 : elapsed.truncatingRemainder(dividingBy: stepDuration) / stepDuration
        let center = CGPoint(x: bounds.midX, y: bounds.midY + 20)
        let stride: CGFloat = 66
        let rise: CGFloat = 24
        // A fixed set of steps moves past the camera; old steps fade at lower left.
        for index in -3...4 {
            let position = CGFloat(index) - CGFloat(phase)
            let opacity = max(0, min(1, (position + 3) / 2)) * max(0, min(1, (4 - position) / 2))
            UIColor.secondaryLabel.withAlphaComponent(0.27 * opacity).setFill()
            context.fill(CGRect(x: center.x + position * stride - 29, y: center.y - position * rise,
                                width: 58, height: 3))
            context.fill(CGRect(x: center.x + position * stride + 26, y: center.y - position * rise + 3,
                                width: 3, height: 12))
        }
        var hop = reduced ? 0 : sin(phase * .pi) * 25
        var squash = 1.0
        if !reduced && !celebrating {
            if phase < 0.12 { squash = 0.80 + phase / 0.12 * 0.20 }
            if phase > 0.84 { squash = 1 - sin((phase - 0.84) / 0.16 * .pi) * 0.22 }
        }
        if celebrating, let end = finishAt, !reduced {
            hop = sin(min(1, (CACurrentMediaTime() - end) / 0.32) * .pi) * 14
        }
        let pixel: CGFloat = 5
        context.saveGState()
        context.translateBy(x: center.x, y: center.y - CGFloat(hop))
        context.scaleBy(x: CGFloat(2 - squash), y: CGFloat(squash))
        context.translateBy(x: -5.5 * pixel, y: -8 * pixel)
        UIColor(red: 0.84, green: 0.46, blue: 0.34, alpha: 1).setFill()
        func block(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            context.fill(CGRect(x: x * pixel, y: y * pixel, width: width * pixel, height: height * pixel))
        }
        // Claude Code's block body, side arms, four feet and two dark eyes.
        block(1, 0, 9, 6)
        block(0, 2, 1, 2)
        block(10, 2, 1, 2)
        for x in [CGFloat(1), 3, 7, 9] { block(x, 6, 1, 2) }
        UIColor(red: 0.12, green: 0.10, blue: 0.09, alpha: 1).setFill()
        block(2, 2, 1, 1)
        block(8, 2, 1, 1)
        context.restoreGState()
    }
}
