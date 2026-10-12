#if DEBUG
import AppKit
import RateSwitcherCore
import SwiftUI

/// Debug-only: `MusicRateSwitcher --snapshot <dir>` renders the UI with demo
/// data to PNG files, used for README screenshots and visual checks.
enum SnapshotRenderer {
    static func run(outputDirectory: URL) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon.png") { NSApp.applicationIconImage = icon }
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            render(PanelView(model: demoModel(playing: true)), to: outputDirectory.appendingPathComponent("panel-\(name).png"), appearance: appearance)
            render(PanelView(model: demoModel(playing: false)), to: outputDirectory.appendingPathComponent("panel-idle-\(name).png"), appearance: appearance)
            renderMenuBar(to: outputDirectory.appendingPathComponent("menubar-\(name).png"), dark: name == "dark")
            render(AboutView(firstLaunch: true) {}, to: outputDirectory.appendingPathComponent("about-\(name).png"), appearance: appearance)
        }
        renderShowcase(to: outputDirectory)
    }

    /// README hero: brand copy on the left, light + dark panels on the right.
    private static func renderShowcase(to directory: URL) {
        guard
            let light = NSImage(contentsOf: directory.appendingPathComponent("panel-light.png")),
            let dark = NSImage(contentsOf: directory.appendingPathComponent("panel-dark.png"))
        else { return }
        let format = SourceAudioFormat(sampleRate: 96_000, bitDepth: 24, channels: 2, codec: "FLAC")
        let chip = StatusItemRenderer.image(style: .compact, phase: .playing, format: format)
        let view = ShowcaseView(light: light, dark: dark, chip: chip)
        render(view, to: directory.appendingPathComponent("showcase.png"), appearance: .darkAqua)
    }

    static func demoModel(playing: Bool) -> PanelModel {
        let model = PanelModel()
        let info = NSDictionary(contentsOfFile: "Resources/Info.plist")
        model.version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let format = SourceAudioFormat(sampleRate: 96_000, bitDepth: 24, channels: 2, codec: "FLAC")
        let dac = AudioOutputDevice(
            id: 1, uid: "dac", name: "MOONDROP Dawn Pro",
            sampleRate: playing ? 96_000 : 44_100,
            supportedRates: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000],
            isDefault: true
        )
        let speakers = AudioOutputDevice(
            id: 2, uid: "builtin", name: "MacBook Pro 扬声器",
            sampleRate: 48_000, supportedRates: [44_100, 48_000, 88_200, 96_000], isDefault: false
        )
        model.devices = [dac, speakers]
        model.selectedDevice = dac
        model.players = [
            PlayerRowState(player: .appleMusic, phase: .waiting, isEnabled: true, isInstalled: true, isActive: false),
            PlayerRowState(player: .neteaseMusic, phase: playing ? .playing(format) : .permissionRequired, isEnabled: true, isInstalled: true, isActive: playing),
            PlayerRowState(
                player: .qqMusic,
                phase: playing ? .playing(SourceAudioFormat(sampleRate: 44_100, bitDepth: 16, channels: 2, codec: "FLAC (QQ)")) : .notRunning,
                isEnabled: true, isInstalled: true, isActive: false
            ),
            PlayerRowState(player: .sodaMusic, phase: .disabled, isEnabled: false, isInstalled: true, isActive: false)
        ]
        if playing {
            model.activeDetection = DetectedSourceFormat(player: .neteaseMusic, format: format)
            model.sync = .matched(96_000)
        }
        model.launchAtLogin = true
        model.launchAtLoginAvailable = true
        return model
    }

    private static func render<V: View>(_ view: V, to url: URL, appearance: NSAppearance.Name) {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        write(view: host, to: url)
        window.orderOut(nil)
    }

    private static func write(view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private struct ShowcaseView: View {
        let light: NSImage
        let dark: NSImage
        let chip: NSImage

        var body: some View {
            ZStack {
                LinearGradient(colors: [Palette.navy, Color(red: 0.05, green: 0.1, blue: 0.27)], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Palette.electric.opacity(0.45), .clear], center: .init(x: 0.78, y: 0.35), startRadius: 0, endRadius: 520)
                WaveGlyph(heights: Self.waveHeights, barWidth: 4)
                .fill(Palette.brandGradient)
                .opacity(0.08)
                .frame(width: 1300, height: 340)

                HStack(alignment: .center, spacing: 70) {
                    copy
                    panels
                }
            }
            .frame(width: 1680, height: 940)
            .clipped()
        }

        private static let waveHeights: [CGFloat] = (0..<70).map { index in
            let x = Double(index) / 69
            let envelope: Double = exp(-pow((x - 0.5) * 3.4, 2))
            let ripple: Double = 0.55 + 0.45 * abs(sin(Double(index) * 1.3))
            return CGFloat(0.04 + 0.9 * envelope * ripple)
        }

        private var copy: some View {
                    VStack(alignment: .leading, spacing: 22) {
                        HStack(spacing: 14) {
                            Image(nsImage: NSImage(contentsOfFile: "Resources/AppIcon.png") ?? NSApp.applicationIconImage)
                                .resizable()
                                .frame(width: 84, height: 84)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("MusicRateSwitcher")
                                    .font(.system(size: 40, weight: .bold))
                                Text("macOS 菜单栏采样率自动匹配")
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.65))
                            }
                        }
                        Text("播放器换到 96 kHz，输出设备也跟着换到 96 kHz。\n告别 macOS 固定采样率带来的隐形重采样。")
                            .font(.system(size: 20))
                            .lineSpacing(6)
                            .foregroundStyle(Color.white.opacity(0.82))
                        HStack(spacing: 10) {
                            ForEach(MusicPlayerID.allCases, id: \.self) { player in
                                HStack(spacing: 7) {
                                    PlayerIcon(player: player, size: 24)
                                    Text(player.displayName).font(.system(size: 14, weight: .medium))
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                            }
                        }
                        HStack(spacing: 12) {
                            Image(nsImage: tinted(chip, color: .white))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: chip.size.width * 2, height: chip.size.height * 2)
                            Text("菜单栏实时显示当前采样率")
                                .font(.system(size: 15))
                                .foregroundStyle(Color.white.opacity(0.6))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.3)))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 640, alignment: .leading)
        }

        private var panels: some View {
            ZStack(alignment: .topLeading) {
                panel(light).offset(x: 0, y: 40).rotationEffect(.degrees(-3))
                panel(dark).offset(x: 230, y: 0)
            }
            .frame(width: 640, height: 820, alignment: .topLeading)
        }

        private func panel(_ image: NSImage) -> some View {
            Image(nsImage: image)
                .resizable()
                .frame(width: image.size.width * 0.95, height: image.size.height * 0.95)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        }

        private func tinted(_ image: NSImage, color: NSColor) -> NSImage {
            NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
    }

    /// Every menu bar style on a fake menu bar strip, idle and playing.
    private static func renderMenuBar(to url: URL, dark: Bool) {
        let format = SourceAudioFormat(sampleRate: 96_000, bitDepth: 24, channels: 2, codec: "FLAC")
        let rows: [(String, NSImage)] = [
            ("待机", StatusItemRenderer.image(style: .compact, phase: .idle, format: nil)),
            ("图标", StatusItemRenderer.image(style: .icon, phase: .playing, format: format)),
            ("紧凑", StatusItemRenderer.image(style: .compact, phase: .playing, format: format)),
            ("切换中", StatusItemRenderer.image(style: .compact, phase: .switching, format: format)),
            ("详细", StatusItemRenderer.image(style: .detailed, phase: .playing, format: format))
        ]
        let scale: CGFloat = 2
        let width: CGFloat = 520, height: CGFloat = 30
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let ink = dark ? NSColor.white : NSColor.black
        var x: CGFloat = 14
        for (label, image) in rows {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                ink.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: x, y: (height - image.size.height) / 2, width: image.size.width, height: image.size.height))
            x += image.size.width + 6
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: ink.withAlphaComponent(0.45)]
            label.draw(at: NSPoint(x: x, y: 9), withAttributes: attributes)
            x += label.size(withAttributes: attributes).width + 22
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
