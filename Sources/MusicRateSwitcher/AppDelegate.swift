import AppKit
import Darwin
import RateSwitcherCore
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, PanelActions {
    private let settings = AppSettings.shared
    private let audio = CoreAudioController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model = PanelModel()
    private let popover = NSPopover()
    private let windows = AuxiliaryWindows()
    private lazy var sources: [MusicPlayerID: SampleRateSource] = [
        .appleMusic: AppleMusicPlaybackMonitor(),
        .neteaseMusic: NeteasePlaybackMonitor(),
        .qqMusic: QQMusicPlaybackMonitor(),
        .sodaMusic: SodaPlaybackMonitor()
    ]

    private var sourceStates: [MusicPlayerID: SampleRateSourceState] = [:]
    private var detections: [MusicPlayerID: DetectedSourceFormat] = [:]
    private var activeDetection: DetectedSourceFormat?
    private var devices: [AudioOutputDevice] = []
    private var switching = false
    private var pendingApply = false
    private var activityTimer: DispatchSourceTimer?
    private var outputActivity: [MusicPlayerID: Bool] = [:]
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.actions = self
        configurePopover()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "音乐播放器自动采样率切换"
        }

        configureSources()
        audio.onDevicesChanged = { [weak self] devices in
            guard let self else { return }
            let previousDefault = self.devices.first(where: \.isDefault)?.uid
            self.devices = devices
            self.refreshUI()
            let currentDefault = devices.first(where: \.isDefault)?.uid
            if previousDefault != nil, previousDefault != currentDefault {
                self.applyCurrentFormat(reason: "默认输出设备已变化")
            }
        }

        devices = audio.outputDevices()
        installTerminationHandlers()
        startActivityPolling()
        refreshUI()
        if NeteaseCacheAccess.shared.startAccess() {
            Diagnostics.shared.info("网易云缓存目录授权已恢复：\(NeteaseCacheAccess.shared.grantedPath ?? "-")")
        }
        for (player, source) in sources where settings.isSourceEnabled(player) { source.start() }
        Diagnostics.shared.info("MusicRateSwitcher 已启动，自动切换=\(settings.autoSwitch)")

        #if DEBUG
        if ProcessInfo.processInfo.environment["MRS_OPEN_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.showPanel() }
        }
        #endif

        if !settings.hasShownWelcome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.windows.showAbout(firstLaunch: true)
                self.settings.hasShownWelcome = true
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activityTimer?.cancel()
        activityTimer = nil
        sources.values.forEach { $0.stop() }
        NeteaseCacheAccess.shared.stopAccess()
        Diagnostics.shared.info("MusicRateSwitcher 已退出")
    }

    private func configurePopover() {
        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
    }

    private func configureSources() {
        for (player, source) in sources {
            sourceStates[player] = .appNotRunning
            source.onStateChanged = { [weak self] state in
                self?.handleState(state, from: player)
            }
            source.onFormatChanged = { [weak self] detection in
                self?.handleDetection(detection)
            }
        }
    }

    private func handleState(_ state: SampleRateSourceState, from player: MusicPlayerID) {
        sourceStates[player] = state
        if player == .neteaseMusic, case .permissionRequired(let directory) = state {
            if model.neteaseCacheHint != directory { model.neteaseCacheHint = directory }
        }
        switch state {
        case .appNotRunning, .waitingForPlayback, .permissionRequired, .error:
            detections[player] = nil
            if activeDetection?.player == player { choosePreferredDetection() }
        case .playing(let detection):
            detections[player] = detection
        case .detecting:
            break
        }
        refreshUI()
    }

    private func handleDetection(_ detection: DetectedSourceFormat) {
        guard settings.isSourceEnabled(detection.player) else { return }
        detections[detection.player] = detection
        refreshOutputActivity(reason: "\(detection.player.displayName) 检测到新曲目", forceApply: true)
    }

    private func choosePreferredDetection() {
        activeDetection = PlaybackArbitrator.preferredDetection(
            from: Array(detections.values),
            enabledPlayers: Set(MusicPlayerID.allCases.filter(settings.isSourceEnabled)),
            outputActivity: outputActivity,
            activitySupported: audio.supportsProcessOutputActivity
        )
    }

    private func startActivityPolling() {
        guard activityTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 0.6, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.refreshOutputActivity(reason: "播放器输出状态变化") }
        activityTimer = timer
        timer.resume()
    }

    private func refreshOutputActivity(reason: String, forceApply: Bool = false) {
        let previousActivity = outputActivity
        let previousPlayer = activeDetection?.player
        var refreshed: [MusicPlayerID: Bool] = [:]
        for player in MusicPlayerID.allCases where settings.isSourceEnabled(player) {
            refreshed[player] = sources[player]?.activityProcessIDs.contains {
                audio.processOutputActivity($0) == true
            } == true
        }
        outputActivity = refreshed
        choosePreferredDetection()

        if refreshed != previousActivity {
            let audible = refreshed.filter(\.value).keys.map(\.displayName).sorted().joined(separator: "、")
            Diagnostics.shared.info("当前实际输出播放器：\(audible.isEmpty ? "无" : audible)")
        }
        if refreshed.values.filter({ $0 }).count > 1 {
            Diagnostics.shared.warning("多个播放器同时输出，采用最近更新的采样率数据")
        }

        let playerChanged = previousPlayer != activeDetection?.player
        if playerChanged || forceApply {
            refreshUI()
            if activeDetection != nil {
                applyCurrentFormat(reason: reason)
            }
        }
    }

    private func installTerminationHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private func refreshUI() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.refreshUI() }
            return
        }
        model.players = MusicPlayerID.allCases.map { player in
            PlayerRowState(
                player: player,
                phase: phase(for: player),
                isEnabled: settings.isSourceEnabled(player),
                isInstalled: player.applicationURL != nil,
                isActive: activeDetection?.player == player
            )
        }
        if model.activeDetection != activeDetection { model.activeDetection = activeDetection }
        if model.devices != devices { model.devices = devices }
        let selected = selectedDevice
        if model.selectedDevice != selected { model.selectedDevice = selected }
        model.followsSystemDefault = settings.selectedDeviceUID == nil
        model.autoSwitch = settings.autoSwitch
        model.launchAtLogin = launchAtLoginEnabled
        model.launchAtLoginAvailable = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        model.menuBarStyle = settings.menuBarStyle
        let granted = NeteaseCacheAccess.shared.grantedPath
        if model.neteaseGrantedPath != granted { model.neteaseGrantedPath = granted }
        if activeDetection == nil, !switching { model.sync = .idle }
        updateStatusButton()
    }

    private var selectedDevice: AudioOutputDevice? {
        if let uid = settings.selectedDeviceUID, let device = devices.first(where: { $0.uid == uid }) { return device }
        return devices.first(where: \.isDefault)
    }

    private func phase(for player: MusicPlayerID) -> PlayerPhase {
        guard settings.isSourceEnabled(player) else { return .disabled }
        switch sourceStates[player] ?? .appNotRunning {
        case .appNotRunning: return .notRunning
        case .waitingForPlayback: return .waiting
        case .detecting: return .detecting
        case .playing(let detection): return .playing(detection.format)
        case .permissionRequired: return .permissionRequired
        case .error(let message): return .error(message)
        }
    }

    private func sourceTitle(for player: MusicPlayerID) -> String {
        guard settings.isSourceEnabled(player) else { return "\(player.displayName)：已禁用" }
        switch sourceStates[player] ?? .appNotRunning {
        case .appNotRunning: return "\(player.displayName)：未运行"
        case .waitingForPlayback: return "\(player.displayName)：等待播放"
        case .detecting: return "\(player.displayName)：正在识别音频格式…"
        case .playing(let detection):
            let marker = activeDetection?.player == player ? " ●" : ""
            return "\(player.displayName)：\(detection.format.description)\(marker)"
        case .permissionRequired: return "\(player.displayName)：需要授权读取播放器数据"
        case .error(let message): return "\(player.displayName)：\(message)"
        }
    }

    private var outputTitle: String {
        guard let device = selectedDevice else { return "输出：不可用" }
        return "输出：\(device.name) · \(SourceAudioFormat.formatRate(device.sampleRate))"
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let phase: StatusItemRenderer.Phase
        if activeDetection == nil { phase = .idle }
        else if switching { phase = .switching }
        else { phase = .playing }
        button.image = StatusItemRenderer.image(style: settings.menuBarStyle, phase: phase, format: activeDetection?.format)
        button.title = ""
        button.imagePosition = .imageOnly
        let rate = activeDetection.map { SourceAudioFormat.formatRate($0.format.sampleRate) } ?? "等待播放"
        button.setAccessibilityLabel("MusicRateSwitcher，\(rate)")
        let sourceSummary = MusicPlayerID.allCases.map(sourceTitle).joined(separator: "\n")
        button.toolTip = "\(sourceSummary)\n\(outputTitle)"
    }

    // MARK: - Popover

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            statusItem.menu = contextMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        devices = audio.outputDevices()
        refreshUI()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let automatic = NSMenuItem(title: "自动匹配采样率", action: #selector(toggleAutomaticFromMenu(_:)), keyEquivalent: "")
        automatic.state = settings.autoSwitch ? .on : .off
        menu.addItem(automatic)
        menu.addItem(NSMenuItem(title: "立即重新检测", action: #selector(refreshFromMenu(_:)), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "关于 MusicRateSwitcher", action: #selector(aboutFromMenu(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "退出 MusicRateSwitcher", action: #selector(quitFromMenu(_:)), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func toggleAutomaticFromMenu(_ sender: Any?) { setAutomatic(!settings.autoSwitch) }
    @objc private func refreshFromMenu(_ sender: Any?) { refreshNow() }
    @objc private func aboutFromMenu(_ sender: Any?) { showAbout() }
    @objc private func quitFromMenu(_ sender: Any?) { quit() }

    private func applyCurrentFormat(reason: String) {
        guard settings.autoSwitch, let detection = activeDetection else { return }
        if switching {
            pendingApply = true
            return
        }
        switching = true
        pendingApply = false
        let format = detection.format
        model.sync = .switching(format.sampleRate)
        refreshUI()
        audio.switchSampleRate(sourceRate: format.sampleRate, deviceUID: settings.selectedDeviceUID) { [weak self] result in
            guard let self else { return }
            self.switching = false
            switch result {
            case .unchanged(_, let rate):
                self.model.sync = abs(rate - format.sampleRate) < 0.5
                    ? .matched(rate)
                    : .fallback(requested: format.sampleRate, applied: rate)
            case .changed(_, let requested, let applied):
                self.model.sync = abs(requested - applied) < 0.5
                    ? .matched(applied)
                    : .fallback(requested: requested, applied: applied)
            case .failed(let message):
                self.model.sync = .failed(message)
                Diagnostics.shared.error("\(reason)：\(message)")
            }
            self.devices = self.audio.outputDevices()
            self.refreshUI()
            if self.pendingApply { self.applyCurrentFormat(reason: "处理切换期间收到的新状态") }
        }
    }

    // MARK: - PanelActions

    func setAutomatic(_ enabled: Bool) {
        settings.autoSwitch = enabled
        Diagnostics.shared.info("自动切换=\(settings.autoSwitch)")
        refreshUI()
        if settings.autoSwitch { applyCurrentFormat(reason: "用户开启自动切换") }
    }

    func setPlayer(_ player: MusicPlayerID, enabled: Bool) {
        guard let source = sources[player], settings.isSourceEnabled(player) != enabled else { return }
        settings.setSourceEnabled(enabled, player: player)
        if enabled {
            source.start()
        } else {
            source.stop()
            sourceStates[player] = .appNotRunning
            detections[player] = nil
            if activeDetection?.player == player { choosePreferredDetection() }
        }
        Diagnostics.shared.info("\(player.displayName) 数据源=\(enabled)")
        refreshUI()
        if enabled { source.refreshNow() }
    }

    func setMenuBarStyle(_ style: MenuBarStyle) {
        settings.menuBarStyle = style
        refreshUI()
    }

    func selectDevice(uid: String?) {
        settings.selectedDeviceUID = uid
        Diagnostics.shared.info("目标设备=\(settings.selectedDeviceUID ?? "系统默认")")
        refreshUI()
        applyCurrentFormat(reason: "用户更改目标设备")
    }

    func refreshNow() {
        audio.refresh()
        for (player, source) in sources where settings.isSourceEnabled(player) { source.refreshNow() }
        applyCurrentFormat(reason: "用户手动刷新")
    }

    func openPlayer(_ player: MusicPlayerID) {
        guard let url = player.applicationURL else { return }
        popover.performClose(nil)
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// NetEase keeps its playback cache inside its own sandbox container, which
    /// macOS protects as "other app data": the consent dialog only lasts for
    /// one run and the Files & Folders switch does not persist, so the file
    /// picker grant is what we store (as a security-scoped bookmark).
    func openNeteaseCachePicker() {
        popover.performClose(nil)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "授权"
        panel.message = "选中网易云音乐的 \(NeteaseCacheAccess.cacheFolderName) 缓存目录。MusicRateSwitcher 只读取其中的缓存文件头部，用来识别当前曲目的采样率。"
        panel.directoryURL = NeteaseCacheAccess.defaultPickerDirectory(
            hint: model.neteaseCacheHint.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let stored = NeteaseCacheAccess.shared.grant(url)
        Diagnostics.shared.info("已授权网易云缓存目录：\(url.path)（bookmark=\(stored ? "已保存" : "未保存")）")
        refreshUI()
        sources[.neteaseMusic]?.refreshNow()
        verifyNeteaseAccess(at: url, stored: stored)
    }

    /// The picker grant applies right away. If macOS still refuses the read the
    /// user has to fall back to Full Disk Access — say so instead of leaving a
    /// silent "需要授权" row behind.
    private func verifyNeteaseAccess(at url: URL, stored: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let readable = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) != nil
            guard readable else {
                Diagnostics.shared.warning("已选择 \(url.path)，但 macOS 仍然拒绝读取，需要完全磁盘访问权限")
                self.showAlert(
                    title: "系统仍然拒绝读取",
                    message: "目录已记录，但 macOS 依然不允许访问。请在面板中点“完全磁盘访问”，把 MusicRateSwitcher 加入列表，然后退出并重新打开它。"
                )
                return
            }
            Diagnostics.shared.info("网易云缓存目录授权校验通过")
            if !stored {
                Diagnostics.shared.warning("该目录的授权记录未能保存，重启 App 后可能需要重新授权")
            }
            self.sources[.neteaseMusic]?.refreshNow()
        }
    }

    func openFullDiskAccessSettings() {
        popover.performClose(nil)
        NSWorkspace.shared.open(Self.fullDiskAccessSettingsURL)
    }

    func copyNeteaseCachePath() {
        guard let path = model.neteaseCacheHint ?? model.neteaseGrantedPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        Diagnostics.shared.info("已复制网易云缓存路径：\(path)")
    }

    static let fullDiskAccessSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    func openAudioMIDISetup() {
        popover.performClose(nil)
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *), enabled != launchAtLoginEnabled else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            Diagnostics.shared.error("登录启动设置失败：\(error.localizedDescription)")
            showAlert(title: "无法更改登录启动", message: error.localizedDescription)
        }
        refreshUI()
    }

    private var launchAtLoginEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    func showDiagnostics() {
        popover.performClose(nil)
        let sourceText = MusicPlayerID.allCases.map { sourceTitle(for: $0) }.joined(separator: "\n")
        let deviceText = devices.map {
            "• \($0.name) [\($0.uid)]：\(SourceAudioFormat.formatRate($0.sampleRate))\($0.isDefault ? "（默认）" : "")"
        }.joined(separator: "\n")
        let text = """
        应用版本：\(model.version)
        系统：macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        网易云缓存授权：\(NeteaseCacheAccess.shared.grantedPath ?? "未授权")
        \(sourceText)
        \(outputTitle)
        自动切换：\(settings.autoSwitch ? "开启" : "关闭")
        当前播放器：\(activeDetection?.player.displayName ?? "无")
        目标设备：\(settings.selectedDeviceUID ?? "跟随系统默认")
        当前来源：\(activeDetection?.identifier ?? "无")

        音频设备：
        \(deviceText.isEmpty ? "• 无" : deviceText)
        """
        windows.showDiagnostics(text: text)
    }

    func openLog() {
        popover.performClose(nil)
        NSWorkspace.shared.open(Diagnostics.shared.logURL)
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.shared.recentText(), forType: .string)
    }

    func showAbout() {
        popover.performClose(nil)
        windows.showAbout(firstLaunch: false)
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func quit() { NSApp.terminate(nil) }
}
