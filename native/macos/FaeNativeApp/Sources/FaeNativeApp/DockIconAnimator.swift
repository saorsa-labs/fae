import AppKit

/// Renders a small glowing orb as the dock icon and slowly cycles its colour
/// through Fae's palette. Updates at ~4 fps for a gentle, living feel without
/// meaningful CPU cost.
@MainActor
final class DockIconAnimator: ObservableObject {

    // Fae palette stops (HSB) — extracted from the orb engine palettes.
    // We interpolate through these continuously.
    private static let stops: [(h: CGFloat, s: CGFloat, b: CGFloat)] = [
        (270 / 360, 0.15, 0.77),  // heather-mist  #B4A8C4
        (150 / 360, 0.25, 0.50),  // glen-green     #5F7F6F
        (155 / 360, 0.22, 0.61),  // loch-grey-green #7A9B8E
        (24  / 360, 0.45, 0.65),  // autumn-bracken #A67B5B
        (190 / 360, 0.05, 0.83),  // silver-mist    #C8D3D5
        (348 / 360, 0.39, 0.55),  // rowan-berry    #8B4653
        (150 / 360, 0.22, 0.36),  // moss-stone     #4A5D52
        (32  / 360, 0.12, 0.91),  // dawn-light     #E8DED2
    ]

    private var timer: Timer?
    private var phase: CGFloat = 0        // 0..1 wrapping position through stops
    private let iconSize: CGFloat = 256
    private let speed: CGFloat = 0.003    // phase increment per tick (~40s full cycle)

    func start() {
        guard timer == nil else { return }
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        phase += speed
        if phase >= 1 { phase -= 1 }
        render()
    }

    // MARK: - Rendering

    private func render() {
        let color = interpolatedColor()
        let image = drawOrb(color: color)
        NSApplication.shared.applicationIconImage = image
    }

    private func interpolatedColor() -> NSColor {
        let count = CGFloat(Self.stops.count)
        let scaled = phase * count
        let idx = Int(scaled) % Self.stops.count
        let next = (idx + 1) % Self.stops.count
        let frac = scaled - CGFloat(Int(scaled))

        let a = Self.stops[idx]
        let b = Self.stops[next]

        // Interpolate HSB, taking the short path around the hue circle
        var dh = b.h - a.h
        if dh > 0.5 { dh -= 1 }
        if dh < -0.5 { dh += 1 }
        var h = a.h + dh * frac
        if h < 0 { h += 1 }
        if h >= 1 { h -= 1 }
        let s = a.s + (b.s - a.s) * frac
        let br = a.b + (b.b - a.b) * frac

        return NSColor(hue: h, saturation: s, brightness: br, alpha: 1)
    }

    private func drawOrb(color: NSColor) -> NSImage {
        let size = NSSize(width: iconSize, height: iconSize)
        let image = NSImage(size: size)
        image.lockFocus()

        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return image
        }

        let rect = CGRect(origin: .zero, size: size)
        let center = CGPoint(x: iconSize / 2, y: iconSize / 2)
        let radius = iconSize / 2

        // Background: near-black rounded rect (matches app bg)
        let bgPath = CGPath(
            roundedRect: rect,
            cornerWidth: iconSize * 0.22,
            cornerHeight: iconSize * 0.22,
            transform: nil
        )
        ctx.setFillColor(CGColor(red: 0.04, green: 0.043, blue: 0.051, alpha: 1))
        ctx.addPath(bgPath)
        ctx.fillPath()

        // Outer glow — large soft radial
        let glowColor = color.withAlphaComponent(0.18).cgColor
        let clearColor = color.withAlphaComponent(0).cgColor
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [glowColor, clearColor] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(
                gradient,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: radius * 0.95,
                options: []
            )
        }

        // Core orb — bright center fading to the palette colour
        let coreWhite = NSColor.white.withAlphaComponent(0.85).cgColor
        let coreMid = color.withAlphaComponent(0.9).cgColor
        let coreEdge = color.withAlphaComponent(0.25).cgColor
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [coreWhite, coreMid, coreEdge] as CFArray,
            locations: [0, 0.35, 1]
        ) {
            // Offset the light source slightly up-left for depth
            let lightCenter = CGPoint(x: center.x - radius * 0.15, y: center.y + radius * 0.15)
            ctx.drawRadialGradient(
                gradient,
                startCenter: lightCenter,
                startRadius: 0,
                endCenter: center,
                endRadius: radius * 0.42,
                options: []
            )
        }

        // Specular highlight — tiny bright spot
        let specCenter = CGPoint(x: center.x - radius * 0.12, y: center.y + radius * 0.14)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.white.withAlphaComponent(0.7).cgColor,
                NSColor.white.withAlphaComponent(0).cgColor,
            ] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(
                gradient,
                startCenter: specCenter,
                startRadius: 0,
                endCenter: specCenter,
                endRadius: radius * 0.14,
                options: []
            )
        }

        image.unlockFocus()
        return image
    }
}
