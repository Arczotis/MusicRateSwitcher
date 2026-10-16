import AppKit
import RateSwitcherCore
import SwiftUI

// MARK: - Palette

enum Palette {
    static let navy = Color(red: 0.035, green: 0.067, blue: 0.17)
    static let deepBlue = Color(red: 0.08, green: 0.17, blue: 0.43)
    static let electric = Color(red: 0.22, green: 0.47, blue: 1.0)
    static let cyan = Color(red: 0.26, green: 0.83, blue: 1.0)
    static let success = Color(red: 0.2, green: 0.82, blue: 0.5)
    static let warning = Color(red: 1.0, green: 0.68, blue: 0.2)
    static let danger = Color(red: 1.0, green: 0.36, blue: 0.36)

    static let brandGradient = LinearGradient(colors: [electric, cyan], startPoint: .leading, endPoint: .trailing)
}

/// Boolean view state. Plain `@State` is a macro in recent SDKs and the
/// Command Line Tools ship without the SwiftUI macro plugin, so view-local
/// flags live in a tiny observable object instead.
final class Flag: ObservableObject {
    @Published var value = false
}

// MARK: - Root

struct PanelView: View {
    @ObservedObject var model: PanelModel
    static let width: CGFloat = 360

    var body: some View {
        VStack(spacing: 14) {
            HeaderView(model: model)
            NowPlayingCard(model: model)
            PlayersSection(model: model)
            OutputSection(model: model)
            PreferencesSection(model: model)
            FooterView(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: Self.width)
    }
}

// MARK: - Header

private struct HeaderView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 10) {
            BrandMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("MusicRateSwitcher")
                    .font(.system(size: 13.5, weight: .semibold))
                Text(model.autoSwitch ? "自动匹配输出采样率" : "自动匹配已暂停")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(
                get: { model.autoSwitch },
                set: { model.actions?.setAutomatic($0) }
            ))
            .toggleStyle(BrandSwitchStyle(large: true))
            .help("自动匹配采样率")
        }
    }
}

struct BrandMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [Palette.deepBlue, Palette.navy], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
            WaveGlyph(heights: [0.32, 0.62, 1.0, 0.7, 0.4], barWidth: size * 0.075)
                .fill(Palette.brandGradient)
                .frame(width: size * 0.5, height: size * 0.5)
        }
        .frame(width: size, height: size)
        .shadow(color: Palette.electric.opacity(0.35), radius: 4, y: 1)
    }
}

/// Rounded vertical bars, centred vertically — the app's waveform motif.
struct WaveGlyph: Shape {
    var heights: [CGFloat]
    var barWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard heights.count > 1 else { return path }
        let gap = (rect.width - barWidth * CGFloat(heights.count)) / CGFloat(heights.count - 1)
        for (index, fraction) in heights.enumerated() {
            let height = max(barWidth, rect.height * fraction)
            let bar = CGRect(
                x: rect.minX + CGFloat(index) * (barWidth + gap),
                y: rect.midY - height / 2,
                width: barWidth,
                height: height
            )
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        return path
    }
}

// MARK: - Now playing

private struct NowPlayingCard: View {
    @ObservedObject var model: PanelModel

    private var detection: DetectedSourceFormat? { model.activeDetection }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if let detection {
                    PlayerIcon(player: detection.player, size: 18)
                    Text(detection.player.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    LiveBars(color: Palette.cyan)
                        .frame(width: 12, height: 10)
                } else {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 13, weight: .medium))
                    Text("等待播放")
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer(minLength: 6)
                SyncBadge(sync: model.sync, automatic: model.autoSwitch, hasSource: detection != nil)
            }
            .foregroundStyle(Color.white.opacity(0.92))

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(detection.map { SourceAudioFormat.rateNumber($0.format.sampleRate) } ?? "--")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        detection == nil
                            ? AnyShapeStyle(Color.white.opacity(0.35))
                            : AnyShapeStyle(LinearGradient(colors: [.white, Palette.cyan], startPoint: .top, endPoint: .bottom))
                    )
                Text("kHz")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                Spacer()
                if let detection {
                    QualityTag(text: detection.format.qualityLabel)
                }
            }
            .padding(.top, 6)

            Text(formatLine)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.62))
                .lineLimit(1)
                .padding(.top, -2)

            SignalPath(model: model)
                .padding(.top, 14)
        }
        .padding(14)
        .background(CardBackground(active: detection != nil))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.75)
        )
        .shadow(color: Palette.navy.opacity(0.35), radius: 10, y: 4)
        .environment(\.colorScheme, .dark)
    }

    private var formatLine: String {
        guard let format = detection?.format else { return "在任一受支持的播放器中开始播放" }
        var parts: [String] = []
        if let bitDepth = format.bitDepth { parts.append("\(bitDepth)-bit") }
        parts.append(format.codec)
        if let channels = format.channelDescription { parts.append(channels) }
        return parts.joined(separator: " · ")
    }
}

private struct CardBackground: View {
    let active: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: [Palette.navy, Palette.deepBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [Palette.electric.opacity(0.45), .clear],
                center: .init(x: 0.95, y: 0.15),
                startRadius: 0,
                endRadius: 180
            )
            WaveGlyph(
                heights: (0..<26).map { index in
                    let x = Double(index) / 25
                    let envelope = exp(-pow((x - 0.62) * 3.2, 2)) * (0.65 + 0.35 * sin(Double(index) * 1.7))
                    return CGFloat(active ? 0.12 + 0.88 * envelope : 0.06 + 0.16 * envelope)
                },
                barWidth: 2.4
            )
            .fill(LinearGradient(colors: [Palette.electric, Palette.cyan], startPoint: .leading, endPoint: .trailing))
            .opacity(active ? 0.22 : 0.16)
            .frame(width: 190, height: 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 34)
            .padding(.trailing, 10)
        }
    }
}

private struct QualityTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.3)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(text == "Hi-Res" ? Color(red: 1, green: 0.84, blue: 0.45) : Color.white.opacity(0.8))
            .background(
                Capsule().strokeBorder(
                    text == "Hi-Res" ? Color(red: 1, green: 0.8, blue: 0.4).opacity(0.7) : Color.white.opacity(0.3),
                    lineWidth: 1
                )
            )
    }
}

private struct SyncBadge: View {
    let sync: SyncState
    let automatic: Bool
    let hasSource: Bool

    var body: some View {
        HStack(spacing: 4) {
            if case .switching = sync {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
            } else {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
            }
            Text(title).font(.system(size: 10.5, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.16)))
        .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
        .help(helpText)
    }

    private var title: String {
        if !automatic { return "手动模式" }
        guard hasSource else { return "待机" }
        switch sync {
        case .idle: return "待机"
        case .switching: return "正在切换"
        case .matched: return "已匹配"
        case .fallback(_, let applied): return "回退 \(SourceAudioFormat.formatRate(applied))"
        case .failed: return "切换失败"
        }
    }

    private var symbol: String {
        if !automatic { return "hand.raised.fill" }
        guard hasSource else { return "moon.zzz.fill" }
        switch sync {
        case .idle, .switching: return "moon.zzz.fill"
        case .matched: return "checkmark"
        case .fallback: return "arrow.down.right"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        if !automatic { return Color.white.opacity(0.7) }
        guard hasSource else { return Color.white.opacity(0.7) }
        switch sync {
        case .idle: return Color.white.opacity(0.7)
        case .switching: return Palette.cyan
        case .matched: return Palette.success
        case .fallback: return Palette.warning
        case .failed: return Palette.danger
        }
    }

    private var helpText: String {
        switch sync {
        case .failed(let message): return message
        case .fallback(let requested, let applied):
            return "设备不支持 \(SourceAudioFormat.formatRate(requested))，已使用同家族的 \(SourceAudioFormat.formatRate(applied))"
        default: return ""
        }
    }
}

/// Source → output device, drawn as a tiny signal chain.
private struct SignalPath: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 8) {
            Node(
                symbol: "waveform",
                title: "源",
                value: model.activeDetection.map { SourceAudioFormat.formatRate($0.format.sampleRate) } ?? "—"
            )
            .fixedSize()
            Connector(active: model.activeDetection != nil && isMatched)
            Node(
                symbol: deviceSymbol(model.selectedDevice?.name ?? ""),
                title: model.selectedDevice?.name ?? "无输出设备",
                value: model.selectedDevice.map { SourceAudioFormat.formatRate($0.sampleRate) } ?? "—"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var isMatched: Bool {
        if case .matched = model.sync { return true }
        if case .fallback = model.sync { return true }
        return false
    }

    private struct Node: View {
        let symbol: String
        let title: String
        let value: String

        var body: some View {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(value)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(0.95))
                }
            }
        }
    }

    private struct Connector: View {
        let active: Bool

        var body: some View {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(active ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Color.white.opacity(0.25)))
                    .frame(width: 22, height: 1.5)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(active ? Palette.cyan : Color.white.opacity(0.3))
            }
        }
    }
}

// MARK: - Players

private struct PlayersSection: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(
                title: "播放器",
                trailing: "\(model.players.filter(\.isEnabled).count)/\(model.players.count) 已启用"
            )
            VStack(spacing: 2) {
                ForEach(model.players) { row in
                    PlayerRow(row: row, actions: model.actions)
                }
            }
            .padding(4)
            .background(SectionBackground())
        }
    }
}

private struct PlayerRow: View {
    let row: PlayerRowState
    weak var actions: PanelActions?
    @StateObject private var hovering = Flag()

    var body: some View {
        HStack(spacing: 10) {
            PlayerIcon(player: row.player, size: 26)
                .saturation(row.isEnabled ? 1 : 0)
                .opacity(row.isEnabled ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.player.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(row.isEnabled ? .primary : .secondary)
                HStack(spacing: 4) {
                    Circle().fill(statusColor).frame(width: 5, height: 5)
                    Text(statusText)
                        .font(isPlaying ? .system(size: 10.5, design: .monospaced) : .system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(statusText)
                }
            }
            Spacer(minLength: 6)
            if row.phase == .permissionRequired {
                HStack(spacing: 4) {
                    MiniButton(title: "选择目录", prominent: true) { actions?.openNeteaseCachePicker() }
                        .help("选中网易云音乐的 \(NeteaseCacheAccess.cacheFolderName) 缓存目录；授权一次后无需再管权限")
                    MiniButton(title: "完全磁盘访问", prominent: false) { actions?.openFullDiskAccessSettings() }
                        .help("打开“系统设置 → 隐私与安全性 → 完全磁盘访问权限”，把 MusicRateSwitcher 加入列表后重新打开 App")
                }
            }
            if row.isActive {
                LiveBars(color: Palette.electric)
                    .frame(width: 14, height: 12)
                    .help("正在输出")
            }
            Toggle("", isOn: Binding(
                get: { row.isEnabled },
                set: { actions?.setPlayer(row.player, enabled: $0) }
            ))
            .toggleStyle(BrandSwitchStyle())
            .help(row.isEnabled ? "停用 \(row.player.displayName) 数据源" : "启用 \(row.player.displayName) 数据源")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(row.isActive ? Palette.electric.opacity(0.1) : Color.primary.opacity(hovering.value && row.isInstalled ? 0.06 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering.value = $0 }
        .onTapGesture { if row.isInstalled { actions?.openPlayer(row.player) } }
        .help(row.isInstalled ? "打开 \(row.player.displayName)" : "未安装 \(row.player.displayName)")
    }

    private var isPlaying: Bool {
        if case .playing = row.phase { return true }
        return false
    }

    private var statusText: String {
        switch row.phase {
        case .disabled: return "已停用"
        case .notRunning: return row.isInstalled ? "未运行" : "未安装"
        case .waiting: return "等待播放"
        case .detecting: return "正在识别…"
        case .playing(let format):
            var parts = [SourceAudioFormat.formatRate(format.sampleRate)]
            if let bitDepth = format.bitDepth { parts.append("\(bitDepth)-bit") }
            parts.append(format.codec)
            return parts.joined(separator: " · ")
        case .permissionRequired: return "需要授权读取缓存"
        case .error(let message): return message
        }
    }

    private var statusColor: Color {
        if row.isActive { return Palette.success }
        switch row.phase {
        case .disabled, .notRunning: return Color.secondary.opacity(0.5)
        case .waiting, .detecting: return Palette.warning
        case .playing: return Palette.electric
        case .permissionRequired: return Palette.warning
        case .error: return Palette.danger
        }
    }
}

/// Compact capsule action, used by the permission row.
private struct MiniButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @StateObject private var hovering = Flag()

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(
                        prominent
                            ? Palette.warning.opacity(hovering.value ? 0.85 : 1)
                            : Color.primary.opacity(hovering.value ? 0.2 : 0.1)
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering.value = $0 }
    }
}

struct PlayerIcon: View {
    let player: MusicPlayerID
    let size: CGFloat

    var body: some View {
        if let icon = player.applicationIcon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: player.fallbackSymbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 0.84, height: size * 0.84)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                        .fill(Color(nsColor: player.tint).gradient)
                )
                .frame(width: size, height: size)
        }
    }
}

/// Animated equaliser bars shown next to the player that drives the output.
struct LiveBars: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: proxy.size.width * 0.14) {
                    ForEach(0..<3) { index in
                        let phase = t * (4.2 + Double(index) * 1.3) + Double(index) * 1.9
                        let fraction = 0.3 + 0.7 * abs(sin(phase))
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color)
                            .frame(height: proxy.size.height * fraction)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

// MARK: - Output

private struct OutputSection: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "输出设备", trailing: nil)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: deviceSymbol(model.selectedDevice?.name ?? ""))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(LinearGradient(colors: [Palette.electric, Palette.cyan.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.selectedDevice?.name ?? "没有可用的输出设备")
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(model.followsSystemDefault ? "跟随系统默认输出" : "已固定此设备")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    DeviceMenu(model: model)
                }

                if let device = model.selectedDevice, !device.supportedRates.isEmpty {
                    RateChips(
                        rates: device.supportedRates,
                        current: device.sampleRate,
                        requested: model.activeDetection?.format.sampleRate
                    )
                }
            }
            .padding(10)
            .background(SectionBackground())
        }
    }
}

private struct DeviceMenu: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Menu {
            Button {
                model.actions?.selectDevice(uid: nil)
            } label: {
                checkLabel("跟随系统默认", checked: model.followsSystemDefault)
            }
            Divider()
            ForEach(model.devices) { device in
                Button {
                    model.actions?.selectDevice(uid: device.uid)
                } label: {
                    checkLabel(
                        device.isDefault ? "\(device.name)（系统默认）" : device.name,
                        checked: !model.followsSystemDefault && model.selectedDevice?.uid == device.uid
                    )
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("更换")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    @ViewBuilder
    private func checkLabel(_ title: String, checked: Bool) -> some View {
        if checked {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

private struct RateChips: View {
    let rates: [Double]
    let current: Double
    let requested: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("设备支持的采样率 · kHz")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 3) {
                ForEach(Array(Set(rates)).sorted(), id: \.self) { rate in
                    chip(rate)
                }
            }
        }
    }

    private func chip(_ rate: Double) -> some View {
        let isCurrent = abs(rate - current) < 0.5
        let isRequested = requested.map { abs(rate - $0) < 0.5 } ?? false
        return Text(SourceAudioFormat.rateNumber(rate))
            .font(.system(size: 10, weight: isCurrent ? .bold : .medium, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(isCurrent ? Color.white : Color.primary.opacity(0.75))
            .background(
                Capsule().fill(isCurrent ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.06)))
            )
            .overlay(
                Capsule().strokeBorder(
                    isRequested && !isCurrent ? Palette.warning : .clear,
                    style: StrokeStyle(lineWidth: 1, dash: [2.5, 1.5])
                )
            )
            .help(isCurrent ? "当前输出采样率" : isRequested ? "源采样率（设备当前未使用）" : "")
    }
}

/// Minimal wrapping layout for chips (macOS 13+).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Preferences

private struct PreferencesSection: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "偏好设置", trailing: nil)
            VStack(spacing: 0) {
                PreferenceRow(symbol: "menubar.rectangle", title: "菜单栏样式") {
                    SegmentedChoice(
                        options: MenuBarStyle.allCases,
                        selection: model.menuBarStyle,
                        title: \.title
                    ) { model.actions?.setMenuBarStyle($0) }
                }
                Divider().padding(.leading, 36)
                PreferenceRow(symbol: "power", title: "登录时启动") {
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.actions?.setLaunchAtLogin($0) }
                    ))
                    .toggleStyle(BrandSwitchStyle())
                    .disabled(!model.launchAtLoginAvailable)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(SectionBackground())
        }
    }
}

private struct PreferenceRow<Accessory: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26)
            Text(title).font(.system(size: 12.5))
            Spacer()
            accessory
        }
        .frame(height: 34)
    }
}

// MARK: - Footer

private struct FooterView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 2) {
            FooterButton(symbol: "arrow.clockwise", help: "立即重新检测 (⌘R)") { model.actions?.refreshNow() }
                .keyboardShortcut("r", modifiers: .command)
            FooterButton(symbol: "slider.horizontal.3", help: "打开“音频 MIDI 设置”") { model.actions?.openAudioMIDISetup() }
            Menu {
                Button("显示诊断摘要") { model.actions?.showDiagnostics() }
                Button("打开日志文件") { model.actions?.openLog() }
                Button("复制最近日志") { model.actions?.copyDiagnostics() }
                Divider()
                Button("选择网易云缓存目录") { model.actions?.openNeteaseCachePicker() }
                Button("复制网易云缓存路径") { model.actions?.copyNeteaseCachePath() }
                Button("完全磁盘访问权限") { model.actions?.openFullDiskAccessSettings() }
            } label: {
                Image(systemName: "stethoscope")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 30, height: 26)
            .help("诊断")
            FooterButton(symbol: "info.circle", help: "关于 MusicRateSwitcher") { model.actions?.showAbout() }
            Spacer()
            Text("v\(model.version)")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.trailing, 4)
            FooterButton(symbol: "power", help: "退出 MusicRateSwitcher (⌘Q)") { model.actions?.quit() }
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.top, 2)
    }
}

private struct FooterButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @StateObject private var hovering = Flag()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(hovering.value ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering.value = $0 }
        .help(help)
    }
}

// MARK: - Shared pieces

/// Capsule switch in the brand gradient; looks the same whether or not the
/// popover is key, unlike the system switch which greys out.
struct BrandSwitchStyle: ToggleStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let width: CGFloat = large ? 38 : 30
        let height: CGFloat = large ? 22 : 17
        return ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            Capsule()
                .fill(configuration.isOn ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.16)))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                .padding(2)
        }
        .frame(width: width, height: height)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { configuration.isOn.toggle() }
        }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(configuration.isOn ? "开" : "关")
    }
}

struct SegmentedChoice<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let title: KeyPath<Option, String>
    let onSelect: (Option) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Text(option[keyPath: title])
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .frame(width: 44, height: 20)
                    .background(
                        Capsule().fill(selected ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Color.clear))
                    )
                    .contentShape(Capsule())
                    .onTapGesture { onSelect(option) }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

private struct SectionTitle: View {
    let title: String
    let trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct SectionBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

func deviceSymbol(_ deviceName: String) -> String {
    let name = deviceName.lowercased()
    if name.contains("airpods") { return "airpodspro" }
    if name.contains("耳机") || name.contains("headphone") || name.contains("headset") { return "headphones" }
    if name.contains("hdmi") || name.contains("display") || name.contains("显示器") { return "tv" }
    if name.contains("dac") || name.contains("usb") || name.contains("interface") { return "hifispeaker.fill" }
    return "speaker.wave.2.fill"
}
