import AppKit
import RateSwitcherCore
import SwiftUI

/// Hosts the About/Welcome and Diagnostics windows. Each is created lazily and
/// reused so repeated clicks just bring the existing window forward.
final class AuxiliaryWindows {
    static let repositoryURL = URL(string: "https://github.com/Arczotis/MusicRateSwitcher")!
    static let releasesURL = URL(string: "https://github.com/Arczotis/MusicRateSwitcher/releases")!
    static let email = "841530503@qq.com"

    private var aboutWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?

    func showAbout(firstLaunch: Bool) {
        let view = AboutView(firstLaunch: firstLaunch) { [weak self] in self?.aboutWindow?.close() }
        aboutWindow = present(aboutWindow, title: firstLaunch ? "欢迎使用" : "关于 MusicRateSwitcher", view: view)
    }

    func showDiagnostics(text: String) {
        let view = DiagnosticsView(text: text)
        diagnosticsWindow = present(diagnosticsWindow, title: "诊断摘要", view: view, resizable: true)
    }

    private func present<Content: View>(_ existing: NSWindow?, title: String, view: Content, resizable: Bool = false) -> NSWindow {
        let window = existing ?? makeWindow(resizable: resizable)
        window.title = title
        let host = NSHostingController(rootView: view)
        window.contentViewController = host
        window.setContentSize(host.view.fittingSize)
        if existing == nil { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeWindow(resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        return window
    }
}

// MARK: - About

struct AboutView: View {
    let firstLaunch: Bool
    let dismiss: () -> Void

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LinearGradient(colors: [Palette.navy, Palette.deepBlue], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Palette.electric.opacity(0.5), .clear], center: .center, startRadius: 0, endRadius: 180)
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 92, height: 92)
                        .shadow(color: Palette.electric.opacity(0.6), radius: 18, y: 4)
                    Text(firstLaunch ? "欢迎使用 MusicRateSwitcher" : "MusicRateSwitcher")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Text("版本 \(version)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                .padding(.top, 30)
                .padding(.bottom, 22)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 16) {
                Text("自动识别播放器当前曲目的源采样率，并把 macOS 输出设备切换到匹配的格式，减少不必要的重采样。")
                    .font(.system(size: 12.5))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 14) {
                    ForEach(MusicPlayerID.allCases, id: \.self) { player in
                        VStack(spacing: 5) {
                            PlayerIcon(player: player, size: 34)
                            Text(player.displayName)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if firstLaunch {
                    VStack(alignment: .leading, spacing: 8) {
                        Tip(symbol: "menubar.arrow.up.rectangle", text: "点击菜单栏中的波形图标打开控制面板")
                        Tip(symbol: "play.circle", text: "在任一受支持的播放器中开始播放即可自动匹配")
                        Tip(symbol: "lock.shield", text: "读取网易云缓存需要授权：系统设置 → 隐私与安全性 → 文件与文件夹")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                }

                VStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(AuxiliaryWindows.repositoryURL)
                    } label: {
                        Label("在 GitHub 上点个 Star", systemImage: "star.fill")
                    }
                    .buttonStyle(BrandButtonStyle(prominent: true))

                    Button(firstLaunch ? "开始使用" : "关闭", action: dismiss)
                        .buttonStyle(BrandButtonStyle(prominent: false))
                        .keyboardShortcut(.defaultAction)
                }

                HStack(spacing: 6) {
                    Text("Arczotis")
                    Text("·")
                    Link(AuxiliaryWindows.email, destination: URL(string: "mailto:\(AuxiliaryWindows.email)")!)
                    Text("·")
                    Text("MIT License")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            }
            .padding(22)
        }
        .frame(width: 380)
        .ignoresSafeArea()
    }

    private struct Tip: View {
        let symbol: String
        let text: String

        var body: some View {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.electric)
                    .frame(width: 18)
                Text(text).font(.system(size: 11.5))
            }
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsView: View {
    let text: String
    @StateObject private var copied = Flag()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.brandGradient))
                VStack(alignment: .leading, spacing: 1) {
                    Text("诊断摘要").font(.system(size: 15, weight: .semibold))
                    Text("反馈问题时附上这段信息会很有帮助").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 240)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            HStack {
                Button("打开日志文件") { NSWorkspace.shared.open(Diagnostics.shared.logURL) }
                Spacer()
                Button(copied.value ? "已复制" : "复制摘要") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied.value = true
                }
                .buttonStyle(BrandButtonStyle(prominent: true, fullWidth: false))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .frame(minWidth: 460, idealWidth: 480, minHeight: 380)
    }
}

struct BrandButtonStyle: ButtonStyle {
    var prominent: Bool
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Palette.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(prominent ? 0 : 0.08), lineWidth: 0.5)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}
