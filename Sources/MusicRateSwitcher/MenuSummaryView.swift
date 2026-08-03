import AppKit

final class MenuSummaryView: NSView {
    static let preferredSize = NSSize(width: 352, height: 58)

    init(subtitle: String, automatic: Bool) {
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
        translatesAutoresizingMaskIntoConstraints = false

        let appIcon = NSImageView(image: symbol("waveform.circle.fill", pointSize: 27) ?? NSImage())
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        appIcon.contentTintColor = .controlAccentColor
        appIcon.imageScaling = .scaleProportionallyDown

        let title = NSTextField(labelWithString: "MusicRateSwitcher")
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 10.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [title, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let badge = StatusBadgeView(text: automatic ? "自动匹配" : "手动模式", active: automatic)
        let header = NSStackView(views: [appIcon, labels, badge])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(header)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.preferredSize.width),
            heightAnchor.constraint(equalToConstant: Self.preferredSize.height),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            header.centerYAnchor.constraint(equalTo: centerYAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 30),
            appIcon.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class PlayerSummaryMenuView: NSView {
    static let preferredHeight: CGFloat = 42

    private let activation: () -> Void
    private var tracking: NSTrackingArea?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    init(
        name: String,
        detail: String,
        symbolName: String,
        statusColor: NSColor,
        action: @escaping () -> Void
    ) {
        activation = action
        super.init(frame: NSRect(x: 0, y: 0, width: MenuSummaryView.preferredSize.width, height: Self.preferredHeight))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("打开 \(name)，\(detail)")

        let icon = NSImageView(image: symbol(symbolName, pointSize: 14) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyDown

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .monospacedSystemFont(ofSize: 9.8, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 0

        let dot = StatusDotView(color: statusColor)
        let chevron = NSImageView(image: symbol("chevron.right", pointSize: 9) ?? NSImage())
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.contentTintColor = .tertiaryLabelColor

        addSubview(icon)
        addSubview(labels)
        addSubview(dot)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 19),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: dot.leadingAnchor, constant: -8),
            dot.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 8),
            chevron.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func mouseDown(with event: NSEvent) { performActivation() }

    override func accessibilityPerformPress() -> Bool {
        performActivation()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 9, dy: 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(isHovering ? 0.17 : 0.10).setFill()
        NSBezierPath(roundedRect: card, xRadius: 8, yRadius: 8).fill()
    }

    private func performActivation() {
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async { [activation] in activation() }
    }
}

private final class StatusDotView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

private final class StatusBadgeView: NSView {
    private let text: String
    private let active: Bool

    init(text: String, active: Bool) {
        self.text = text
        self.active = active
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 61),
            heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = active ? .systemGreen : .secondaryLabelColor
        color.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: color
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}

private func symbol(_ name: String, pointSize: CGFloat) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium))
}
