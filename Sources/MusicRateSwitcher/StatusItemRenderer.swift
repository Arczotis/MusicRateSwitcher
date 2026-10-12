import AppKit
import RateSwitcherCore

/// Draws the menu bar glyph as a template image so it follows the menu bar's
/// light/dark appearance and the system's selection highlight.
enum StatusItemRenderer {
    enum Phase {
        case idle
        case playing
        case switching
    }

    private static let height: CGFloat = 22
    private static let glyphWidth: CGFloat = 15

    static func image(style: MenuBarStyle, phase: Phase, format: SourceAudioFormat?) -> NSImage {
        guard let format, phase != .idle, style != .icon else {
            return glyphOnly(lively: phase != .idle)
        }
        switch style {
        case .icon:
            return glyphOnly(lively: true)
        case .compact:
            return compact(format: format, outlined: phase == .switching)
        case .detailed:
            return detailed(format: format, outlined: phase == .switching)
        }
    }

    // MARK: - Styles

    private static func glyphOnly(lively: Bool) -> NSImage {
        makeImage(width: glyphWidth + 2) { _ in
            drawGlyph(in: NSRect(x: 1, y: 0, width: glyphWidth, height: height), lively: lively)
        }
    }

    /// A filled capsule with the rate knocked out of it: `[ 96 kHz ]`.
    private static func compact(format: SourceAudioFormat, outlined: Bool) -> NSImage {
        let number = SourceAudioFormat.rateNumber(format.sampleRate)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)
        let unitFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        let text = NSMutableAttributedString(string: number, attributes: [.font: numberFont, .foregroundColor: NSColor.black])
        text.append(NSAttributedString(string: " kHz", attributes: [
            .font: unitFont, .foregroundColor: NSColor.black, .baselineOffset: 0.5
        ]))
        let textSize = text.size()
        let capsuleWidth = ceil(textSize.width) + 12
        let width = glyphWidth + 4 + capsuleWidth + 1

        return makeImage(width: width) { context in
            drawGlyph(in: NSRect(x: 0, y: 0, width: glyphWidth, height: height), lively: true)
            let capsule = NSRect(x: glyphWidth + 4, y: 3.5, width: capsuleWidth, height: height - 7)
            let path = NSBezierPath(roundedRect: capsule, xRadius: 4.5, yRadius: 4.5)
            let origin = NSPoint(x: capsule.midX - textSize.width / 2, y: capsule.midY - textSize.height / 2 + 0.5)
            if outlined {
                path.lineWidth = 1.2
                NSColor.black.setStroke()
                path.stroke()
                text.draw(at: origin)
            } else {
                NSColor.black.setFill()
                path.fill()
                context.compositingOperation = .destinationOut
                text.draw(at: origin)
                context.compositingOperation = .sourceOver
            }
        }
    }

    /// Two stacked lines: rate on top, bit depth and codec underneath.
    private static func detailed(format: SourceAudioFormat, outlined: Bool) -> NSImage {
        let top = NSAttributedString(
            string: SourceAudioFormat.formatRate(format.sampleRate),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold),
                .foregroundColor: NSColor.black
            ]
        )
        var detail: [String] = []
        if let bitDepth = format.bitDepth { detail.append("\(bitDepth)-BIT") }
        detail.append(shortCodec(format.codec))
        let bottom = NSAttributedString(
            string: detail.joined(separator: " · "),
            attributes: [
                .font: NSFont.systemFont(ofSize: 7.5, weight: .semibold),
                .foregroundColor: NSColor.black.withAlphaComponent(outlined ? 0.45 : 0.7),
                .kern: 0.3
            ]
        )
        let textWidth = ceil(max(top.size().width, bottom.size().width))
        let width = glyphWidth + 5 + textWidth + 1

        return makeImage(width: width) { _ in
            drawGlyph(in: NSRect(x: 0, y: 0, width: glyphWidth, height: height), lively: !outlined)
            let x = glyphWidth + 5
            top.draw(at: NSPoint(x: x, y: 10))
            bottom.draw(at: NSPoint(x: x, y: 1.5))
        }
    }

    // MARK: - Drawing helpers

    /// Five rounded bars echoing the app icon's waveform.
    private static func drawGlyph(in rect: NSRect, lively: Bool) {
        let heights: [CGFloat] = lively ? [0.36, 0.7, 1.0, 0.62, 0.3] : [0.22, 0.34, 0.46, 0.34, 0.22]
        let barWidth: CGFloat = 2
        let gap = (rect.width - barWidth * CGFloat(heights.count)) / CGFloat(heights.count - 1)
        let maxHeight = rect.height - 8
        NSColor.black.withAlphaComponent(lively ? 1 : 0.85).setFill()
        for (index, fraction) in heights.enumerated() {
            let barHeight = max(barWidth, maxHeight * fraction)
            let bar = NSRect(
                x: rect.minX + CGFloat(index) * (barWidth + gap),
                y: rect.midY - barHeight / 2,
                width: barWidth,
                height: barHeight
            )
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    private static func makeImage(width: CGFloat, draw: @escaping (NSGraphicsContext) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            draw(context)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func shortCodec(_ codec: String) -> String {
        if codec == "QQ Music" { return "QQ" }
        let trimmed = codec
            .replacingOccurrences(of: " (QQ)", with: "")
            .replacingOccurrences(of: " (CENC)", with: "")
            .uppercased()
        return trimmed.count > 6 ? String(trimmed.prefix(6)) : trimmed
    }
}
