import AppKit
import QuartzCore
import SwiftUI

// The two things in the window that move on their own, the listening pulse and the
// answer placeholder's shimmer, are Core Animation layers rather than SwiftUI
// animations. Core Animation runs them in the render server, so a call that lasts an
// hour costs the main thread nothing per frame. Both stop while the window is hidden
// or covered, and stay still with Reduce Motion.

/// The red dot in the Listening pill, with a halo that keeps expanding from it.
struct ListeningPulse: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> PulseView {
        PulseView()
    }

    func updateNSView(_ view: PulseView, context: Context) {
        view.reduceMotion = reduceMotion
    }
}

/// Three rounded bars with a highlight sweeping across them, while an answer has no
/// words yet.
struct ShimmerBars: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ShimmerView {
        ShimmerView()
    }

    func updateNSView(_ view: ShimmerView, context: Context) {
        view.reduceMotion = reduceMotion
    }
}

/// A layer-backed view whose repeating animation runs only while its window is on
/// screen and Reduce Motion is off.
class OcclusionAwareLayerView: NSView {
    var reduceMotion = false {
        didSet {
            if reduceMotion != oldValue {
                updateAnimation()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        if let window {
            center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        if let newWindow {
            center.addObserver(
                self, selector: #selector(occlusionChanged), name: NSWindow.didChangeOcclusionStateNotification,
                object: newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
        updateAnimation()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        CATransaction.commit()
    }

    @objc private func occlusionChanged(_ notification: Notification) {
        updateAnimation()
    }

    private func updateAnimation() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        setAnimating(visible && !reduceMotion)
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            applyColors(dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
    }

    func layoutLayers() {}
    func applyColors(dark: Bool) {}
    func setAnimating(_ animating: Bool) {}
}

final class PulseView: OcclusionAwareLayerView {
    private let halo = CALayer()
    private let dot = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer?.addSublayer(halo)
        layer?.addSublayer(dot)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutLayers() {
        let size: CGFloat = 8
        let rect = CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        for circle in [halo, dot] {
            circle.frame = rect
            circle.cornerRadius = size / 2
        }
    }

    override func applyColors(dark: Bool) {
        halo.backgroundColor = NSColor.systemRed.cgColor
        dot.backgroundColor = NSColor.systemRed.cgColor
    }

    override func setAnimating(_ animating: Bool) {
        halo.removeAnimation(forKey: "pulse")
        guard animating else {
            // A still ring keeps the dot recognisable as the recording light.
            halo.opacity = 0.25
            halo.transform = CATransform3DMakeScale(1.75, 1.75, 1)
            return
        }
        halo.opacity = 0
        halo.transform = CATransform3DIdentity
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.45
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = 1.6
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.repeatCount = .infinity
        halo.add(pulse, forKey: "pulse")
    }
}

final class ShimmerView: OcclusionAwareLayerView {
    private static let widths: [CGFloat] = [0.94, 1, 0.58]
    private static let barHeight: CGFloat = 12
    private static let barGap: CGFloat = 10

    private let bars = ShimmerView.widths.map { _ in CALayer() }
    private let shine = CAGradientLayer()
    private let shineMask = CAShapeLayer()

    static var height: CGFloat {
        CGFloat(widths.count) * barHeight + CGFloat(widths.count - 1) * barGap
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for bar in bars {
            bar.cornerRadius = Self.barHeight / 2
            layer?.addSublayer(bar)
        }
        shine.startPoint = CGPoint(x: 0, y: 0.5)
        shine.endPoint = CGPoint(x: 1, y: 0.5)
        shine.locations = [0, 0.15, 0.3]
        shine.mask = shineMask
        layer?.addSublayer(shine)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutLayers() {
        let path = CGMutablePath()
        for (index, bar) in bars.enumerated() {
            let y = CGFloat(index) * (Self.barHeight + Self.barGap)
            let rect = CGRect(x: 0, y: y, width: bounds.width * Self.widths[index], height: Self.barHeight)
            bar.frame = rect
            path.addRoundedRect(in: rect, cornerWidth: Self.barHeight / 2, cornerHeight: Self.barHeight / 2)
        }
        shine.frame = bounds
        shineMask.frame = bounds
        shineMask.path = path
    }

    override func applyColors(dark: Bool) {
        let bar = dark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.07)
        let highlight = dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 1, alpha: 0.75)
        for layer in bars {
            layer.backgroundColor = bar.cgColor
        }
        shine.colors = [NSColor.clear.cgColor, highlight.cgColor, NSColor.clear.cgColor]
    }

    override func setAnimating(_ animating: Bool) {
        shine.removeAnimation(forKey: "sweep")
        shine.isHidden = !animating
        guard animating else {
            return
        }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-0.3, -0.15, 0]
        sweep.toValue = [1, 1.15, 1.3]
        sweep.duration = 1.3
        sweep.repeatCount = .infinity
        shine.add(sweep, forKey: "sweep")
    }
}
