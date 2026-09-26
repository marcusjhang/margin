import AppKit
import MarginCore
import MarginUI

/// Renders the menu bar glyph as a monochrome **template** image, so macOS
/// tints it like a native status item in both light and dark menu bars.
enum StatusItemGlyph {
    private static let providers: [ProviderID] = [.claude, .codex]

    static func image(for snapshots: [ProviderSnapshot], style: GlyphStyle, watch: Severity = .normal) -> NSImage {
        let base: NSImage
        switch style {
        case .levels: base = levels(snapshots)
        case .ring: base = ring(snapshots)
        case .text: base = text(snapshots)
        }

        // The watch state is independent of usage severity: a hollow ring for
        // warnings, a filled dot for critical alerts. Drawn as an extra element
        // so it never alters the usage bars.
        guard watch != .normal else {
            base.isTemplate = true
            return base
        }

        let padding: CGFloat = 3
        let dot: CGFloat = 5
        let total = NSSize(
            width: base.size.width + dot + padding,
            height: max(base.size.height, dot)
        )

        let image = NSImage(size: total, flipped: false) { rect in
            let baseY = (total.height - base.size.height) / 2
            base.draw(at: NSPoint(x: 0, y: baseY), from: .zero, operation: .sourceOver, fraction: 1.0)
            let dotRect = NSRect(
                x: base.size.width + padding,
                y: (total.height - dot) / 2,
                width: dot,
                height: dot
            )
            let path = NSBezierPath(ovalIn: dotRect)
            if watch == .critical {
                path.fill()
            } else {
                path.lineWidth = 1.2
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func usage(_ provider: ProviderID, _ snapshots: [ProviderSnapshot]) -> Double {
        snapshots.first { $0.provider == provider }?.bindingWindow?.usedPercent ?? 0
    }

    /// Two stacked level bars — one per provider. Clean and native.
    private static func levels(_ snapshots: [ProviderSnapshot]) -> NSImage {
        let width: CGFloat = 15
        let barHeight: CGFloat = 4
        let gap: CGFloat = 3
        let height = barHeight * 2 + gap

        return NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            for (index, provider) in providers.enumerated() {
                let y = height - CGFloat(index + 1) * barHeight - CGFloat(index) * gap
                let trackRect = NSRect(x: 0, y: y, width: width, height: barHeight)
                NSColor.black.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: trackRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

                let fraction = min(max(usage(provider, snapshots) / 100, 0), 1)
                guard fraction > 0 else { continue }
                let fillWidth = max(barHeight, width * fraction)
                let fillRect = NSRect(x: 0, y: y, width: fillWidth, height: barHeight)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            }
            return true
        }
    }

    /// A single ring for whichever resource is most constrained.
    private static func ring(_ snapshots: [ProviderSnapshot]) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let binding = snapshots.max {
            ($0.bindingWindow?.usedPercent ?? 0) < ($1.bindingWindow?.usedPercent ?? 0)
        }
        return NSImage(size: size, flipped: false) { rect in
            let inset = rect.insetBy(dx: 2.5, dy: 2.5)
            let track = NSBezierPath(ovalIn: inset)
            track.lineWidth = 2.5
            NSColor.black.withAlphaComponent(0.28).setStroke()
            track.stroke()

            if let percent = binding?.bindingWindow?.usedPercent, percent > 0 {
                let fraction = min(max(percent / 100, 0), 1)
                let arc = NSBezierPath()
                arc.appendArc(
                    withCenter: NSPoint(x: rect.midX, y: rect.midY),
                    radius: inset.width / 2,
                    startAngle: 90,
                    endAngle: 90 - 360 * fraction,
                    clockwise: true
                )
                arc.lineWidth = 2.5
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
    }

    /// Compact text, e.g. "34 16".
    private static func text(_ snapshots: [ProviderSnapshot]) -> NSImage {
        let string = providers
            .map { provider -> String in
                let used = usage(provider, snapshots)
                return "\(used.isFinite ? Int(min(max(used, 0), 999).rounded()) : 0)"
            }
            .joined(separator: " ")
        let attributed = NSAttributedString(
            string: string,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
        )
        let textSize = attributed.size()
        return NSImage(
            size: NSSize(width: ceil(textSize.width) + 2, height: ceil(textSize.height)),
            flipped: false
        ) { _ in
            attributed.draw(at: NSPoint(x: 1, y: 0))
            return true
        }
    }
}
