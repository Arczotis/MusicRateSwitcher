import AppKit
import Darwin
import RateSwitcherCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let repositoryURL = URL(string: "https://github.com/Arczotis/MusicRateSwitcher")!
    private let settings = AppSettings.shared
    private let audio = CoreAudioController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
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
    private var lastSwitchMessage = "尚未切换"
    private var switching = false
    private var pendingApply = false
    private var activityTimer: DispatchSourceTimer?
    private var outputActivity: [MusicPlayerID: Bool] = [:]
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.delegate = self
        menu.minimumWidth = MenuSummaryView.preferredSize.width
        statusItem.menu = menu
        statusItem.button?.toolTip = "音乐播放器自动采样率切换"

        configureSources()
        audio.onDevicesChanged = { [weak self] devices in
            guard let self else { return }
            let previousDefault = self.devices.first(where: \.isDefault)?.uid
            self.devices = devices
            self.rebuildMenu()
            let currentDefault = devices.first(where: \.isDefault)?.uid
            if previousDefault != nil, previousDefault != currentDefault {
                self.applyCurrentFormat(reason: "默认输出设备已变化")
            }
        }

        devices = audio.outputDevices()
        installTerminationHandlers()
        startActivityPolling()
        rebuildMenu()
        for (player, source) in sources where settings.isSourceEnabled(player) { source.start() }
        Diagnostics.shared.info("MusicRateSwitcher 已启动，自动切换=\(settings.autoSwitch)")

        if !settings.hasShownWelcome {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                self.showProjectInfo(firstLaunch: true)
                self.settings.hasShownWelcome = true
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activityTimer?.cancel()
        activityTimer = nil
        sources.values.forEach { $0.stop() }
        Diagnostics.shared.info("MusicRateSwitcher 已退出")
    }

    func menuWillOpen(_ menu: NSMenu) {
        devices = audio.outputDevices()
        rebuildMenu()
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
        switch state {
        case .appNotRunning, .waitingForPlayback, .error:
            detections[player] = nil
            if activeDetection?.player == player { choosePreferredDetection() }
        case .playing(let detection):
            detections[player] = detection
        case .detecting:
            break
        }
        rebuildMenu()
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
            rebuildMenu()
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

    private func rebuildMenu() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.rebuildMenu() }
            return
        }
        menu.removeAllItems()
        updateStatusButton()

        menu.addItem(makeSummaryItem())
        menu.addItem(.separator())

        for player in MusicPlayerID.allCases {
            menu.addItem(makePlayerSummaryItem(player))
        }
        menu.addItem(makeOutputSummaryItem())
        menu.addItem(.separator())

        menu.addItem(sectionHeader("播放与输出"))

        let automatic = item("自动匹配采样率", #selector(toggleAutomatic(_:)), symbol: "arrow.triangle.2.circlepath")
        automatic.state = settings.autoSwitch ? .on : .off
        menu.addItem(automatic)

        let playersItem = item("播放器数据源", nil, symbol: "music.note.list")
        playersItem.submenu = makePlayersMenu()
        menu.addItem(playersItem)

        let showRate = item("在菜单栏显示采样率", #selector(toggleMenuBarRate(_:)), symbol: "menubar.rectangle")
        showRate.state = settings.showRateInMenuBar ? .on : .off
        menu.addItem(showRate)

        let launch = item("登录时启动", #selector(toggleLaunchAtLogin(_:)), symbol: "power")
        launch.state = launchAtLoginEnabled ? .on : .off
        launch.isEnabled = Bundle.main.bundleURL.pathExtension.lowercased() == "app"
        menu.addItem(launch)
        menu.addItem(.separator())

        menu.addItem(sectionHeader("工具"))
        menu.addItem(item("立即重新检测", #selector(refreshNow(_:)), key: "r", symbol: "arrow.clockwise"))
        let openPlayer = item("打开播放器", nil, symbol: "square.and.arrow.up")
        openPlayer.submenu = makeOpenPlayerMenu()
        menu.addItem(openPlayer)
        menu.addItem(item("打开“音频 MIDI 设置”", #selector(openAudioMIDISetup(_:)), symbol: "slider.horizontal.3"))

        let diagnostics = item("诊断", nil, symbol: "stethoscope")
        let diagnosticsMenu = NSMenu()
        diagnosticsMenu.addItem(item("显示诊断摘要", #selector(showDiagnostics(_:)), symbol: "doc.text.magnifyingglass"))
        diagnosticsMenu.addItem(item("打开日志文件", #selector(openLog(_:)), symbol: "doc.text"))
        diagnosticsMenu.addItem(item("复制最近日志", #selector(copyDiagnostics(_:)), symbol: "doc.on.doc"))
        diagnostics.submenu = diagnosticsMenu
        menu.addItem(diagnostics)

        menu.addItem(.separator())
        menu.addItem(item("关于 MusicRateSwitcher", #selector(showAbout(_:)), symbol: "info.circle"))
        menu.addItem(item("退出 MusicRateSwitcher", #selector(quit(_:)), key: "q", symbol: "power"))
    }

    private func makeSummaryItem() -> NSMenuItem {
        let subtitle: String
        if switching {
            subtitle = "正在同步输出设备…"
        } else if let detection = activeDetection {
            subtitle = "\(detection.player.displayName) · \(SourceAudioFormat.formatRate(detection.format.sampleRate))"
        } else {
            subtitle = "等待播放器输出"
        }
        let view = MenuSummaryView(subtitle: subtitle, automatic: settings.autoSwitch)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func makePlayerSummaryItem(_ player: MusicPlayerID) -> NSMenuItem {
        let detail = playerSummaryDetail(player)
        let view = PlayerSummaryMenuView(
            name: player.displayName,
            detail: detail,
            symbolName: playerSymbol(player),
            statusColor: playerStatusColor(player),
            action: { [weak self] in self?.activatePlayer(player) }
        )
        let item = NSMenuItem()
        item.view = view
        item.toolTip = sourceTitle(for: player)
        return item
    }

    private func playerSummaryDetail(_ player: MusicPlayerID) -> String {
        guard settings.isSourceEnabled(player) else { return "已关闭" }
        switch sourceStates[player] ?? .appNotRunning {
        case .appNotRunning: return "未运行"
        case .waitingForPlayback: return "等待播放"
        case .detecting: return "正在识别…"
        case .playing(let detection): return detection.format.description
        case .error(let message): return message
        }
    }

    private func playerStatusColor(_ player: MusicPlayerID) -> NSColor {
        if activeDetection?.player == player { return .systemGreen }
        guard settings.isSourceEnabled(player) else { return .tertiaryLabelColor }
        switch sourceStates[player] ?? .appNotRunning {
        case .detecting, .waitingForPlayback: return .systemOrange
        case .error: return .systemRed
        case .appNotRunning, .playing: return .secondaryLabelColor
        }
    }

    private func makeOutputSummaryItem() -> NSMenuItem {
        guard let selected = audio.selectedDevice(uid: settings.selectedDeviceUID) else {
            let item = self.item("没有可用的输出设备", nil, symbol: "speaker.slash")
            item.isEnabled = false
            return item
        }
        let rate = SourceAudioFormat.formatRate(selected.sampleRate)
        let item = self.item("\(selected.name)   \(rate)", nil, symbol: outputSymbol(for: selected.name))
        item.submenu = makeDeviceMenu()
        item.toolTip = "点击选择目标输出设备"
        return item
    }

    private func outputSymbol(for deviceName: String) -> String {
        let name = deviceName.lowercased()
        if name.contains("耳机") || name.contains("headphone") || name.contains("airpods") {
            return "headphones"
        }
        return "speaker.wave.2.fill"
    }

    private func makePlayersMenu() -> NSMenu {
        let submenu = NSMenu()
        for player in MusicPlayerID.allCases {
            let menuItem = item(player.displayName, #selector(togglePlayer(_:)), symbol: playerSymbol(player))
            menuItem.representedObject = player.rawValue
            menuItem.state = settings.isSourceEnabled(player) ? .on : .off
            submenu.addItem(menuItem)
        }
        return submenu
    }

    private func makeOpenPlayerMenu() -> NSMenu {
        let submenu = NSMenu()
        for player in MusicPlayerID.allCases {
            let menuItem = item(player.displayName, #selector(openPlayer(_:)), symbol: playerSymbol(player))
            menuItem.representedObject = player.rawValue
            menuItem.isEnabled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) != nil
            submenu.addItem(menuItem)
        }
        return submenu
    }

    private func playerSymbol(_ player: MusicPlayerID) -> String {
        switch player {
        case .appleMusic: return "music.note"
        case .neteaseMusic: return "waveform"
        case .qqMusic: return "music.note.list"
        case .sodaMusic: return "sparkles"
        }
    }

    private func makeDeviceMenu() -> NSMenu {
        let submenu = NSMenu()
        let followDefault = item("跟随系统默认", #selector(selectDevice(_:)), symbol: "arrow.triangle.2.circlepath")
        followDefault.representedObject = "__DEFAULT__"
        followDefault.state = settings.selectedDeviceUID == nil ? .on : .off
        submenu.addItem(followDefault)
        submenu.addItem(.separator())

        for device in devices {
            let suffix = device.isDefault ? "（系统默认）" : ""
            let menuItem = item("\(device.name) \(suffix)", #selector(selectDevice(_:)), symbol: "speaker.wave.2")
            menuItem.representedObject = device.uid
            menuItem.state = settings.selectedDeviceUID == device.uid ? .on : .off
            menuItem.toolTip = "当前 \(SourceAudioFormat.formatRate(device.sampleRate))；支持 \(device.supportedRates.map(SourceAudioFormat.formatRate).joined(separator: ", "))"
            submenu.addItem(menuItem)
        }
        if devices.isEmpty {
            let none = NSMenuItem(title: "没有可用输出设备", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        return submenu
    }

    private func item(_ title: String, _ action: Selector?, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol {
            item.image = symbolImage(symbol)
        }
        return item
    }

    private func sectionHeader(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.4
            ]
        )
        return item
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image?.isTemplate = true
        return image
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
        case .error(let message): return "\(player.displayName)：\(message)"
        }
    }

    private var outputTitle: String {
        guard let device = audio.selectedDevice(uid: settings.selectedDeviceUID) else { return "输出：不可用" }
        return "输出：\(device.name) · \(SourceAudioFormat.formatRate(device.sampleRate))"
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MusicRateSwitcher")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        image?.isTemplate = true
        button.image = image
        button.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
        if settings.showRateInMenuBar, let detection = activeDetection {
            button.title = SourceAudioFormat.formatRate(detection.format.sampleRate)
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
        let sourceSummary = MusicPlayerID.allCases.map(sourceTitle).joined(separator: "\n")
        button.toolTip = "\(sourceSummary)\n\(outputTitle)"
    }

    private func applyCurrentFormat(reason: String) {
        guard settings.autoSwitch, let detection = activeDetection else { return }
        if switching {
            pendingApply = true
            return
        }
        switching = true
        pendingApply = false
        let format = detection.format
        lastSwitchMessage = "\(detection.player.displayName) 正在应用 \(SourceAudioFormat.formatRate(format.sampleRate))…"
        rebuildMenu()
        audio.switchSampleRate(sourceRate: format.sampleRate, deviceUID: settings.selectedDeviceUID) { [weak self] result in
            guard let self else { return }
            self.switching = false
            switch result {
            case .unchanged(let device, let rate):
                self.lastSwitchMessage = "已匹配 \(device.name) · \(SourceAudioFormat.formatRate(rate))"
            case .changed(let device, let requested, let applied):
                if abs(requested - applied) < 0.5 {
                    self.lastSwitchMessage = "已切换 \(device.name) 至 \(SourceAudioFormat.formatRate(applied))"
                } else {
                    self.lastSwitchMessage = "设备不支持源采样率，已使用 \(SourceAudioFormat.formatRate(applied))"
                }
            case .failed(let message):
                self.lastSwitchMessage = message
                Diagnostics.shared.error("\(reason)：\(message)")
            }
            self.devices = self.audio.outputDevices()
            self.rebuildMenu()
            if self.pendingApply { self.applyCurrentFormat(reason: "处理切换期间收到的新状态") }
        }
    }

    @objc private func toggleAutomatic(_ sender: NSMenuItem) {
        settings.autoSwitch.toggle()
        Diagnostics.shared.info("自动切换=\(settings.autoSwitch)")
        rebuildMenu()
        if settings.autoSwitch { applyCurrentFormat(reason: "用户开启自动切换") }
    }

    @objc private func togglePlayer(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let player = MusicPlayerID(rawValue: raw), let source = sources[player] else { return }
        let enabled = !settings.isSourceEnabled(player)
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
        rebuildMenu()
        if enabled { source.refreshNow() }
    }

    @objc private func toggleMenuBarRate(_ sender: NSMenuItem) {
        settings.showRateInMenuBar.toggle()
        rebuildMenu()
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        let value = sender.representedObject as? String
        settings.selectedDeviceUID = value == "__DEFAULT__" ? nil : value
        Diagnostics.shared.info("目标设备=\(settings.selectedDeviceUID ?? "系统默认")")
        rebuildMenu()
        applyCurrentFormat(reason: "用户更改目标设备")
    }

    @objc private func refreshNow(_ sender: Any?) {
        audio.refresh()
        for (player, source) in sources where settings.isSourceEnabled(player) { source.refreshNow() }
        applyCurrentFormat(reason: "用户手动刷新")
    }

    @objc private func openPlayer(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let player = MusicPlayerID(rawValue: raw),
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) != nil
        else { return }
        activatePlayer(player)
    }

    private func activatePlayer(_ player: MusicPlayerID) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: player.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    @objc private func openAudioMIDISetup(_ sender: Any?) {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if launchAtLoginEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            rebuildMenu()
        } catch {
            Diagnostics.shared.error("登录启动设置失败：\(error.localizedDescription)")
            showAlert(title: "无法更改登录启动", message: error.localizedDescription)
        }
    }

    private var launchAtLoginEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    @objc private func showDiagnostics(_ sender: Any?) {
        let sourceText = MusicPlayerID.allCases.map { sourceTitle(for: $0) }.joined(separator: "\n")
        let deviceText = devices.map {
            "• \($0.name) [\($0.uid)]：\(SourceAudioFormat.formatRate($0.sampleRate))\($0.isDefault ? "（默认）" : "")"
        }.joined(separator: "\n")
        let text = """
        应用版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版")
        系统：macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        \(sourceText)
        \(outputTitle)
        自动切换：\(settings.autoSwitch ? "开启" : "关闭")
        当前播放器：\(activeDetection?.player.displayName ?? "无")
        目标设备：\(settings.selectedDeviceUID ?? "跟随系统默认")
        当前来源：\(activeDetection?.identifier ?? "无")

        音频设备：
        \(deviceText.isEmpty ? "• 无" : deviceText)
        """
        showAlert(title: "诊断摘要", message: text)
    }

    @objc private func openLog(_ sender: Any?) { NSWorkspace.shared.open(Diagnostics.shared.logURL) }

    @objc private func copyDiagnostics(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.shared.recentText(), forType: .string)
        lastSwitchMessage = "最近日志已复制"
        rebuildMenu()
    }

    @objc private func showAbout(_ sender: Any?) {
        showProjectInfo(firstLaunch: false)
    }

    private func showProjectInfo(firstLaunch: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = firstLaunch ? "欢迎使用 MusicRateSwitcher" : "关于 MusicRateSwitcher"
        alert.informativeText = """
        自动检测 Apple Music、网易云音乐、QQ 音乐与汽水音乐的源采样率，并匹配 macOS 输出设备。

        这是一个开源项目。如果它对你有帮助，欢迎到 GitHub 点一个 Star ⭐️

        仓库：https://github.com/Arczotis/MusicRateSwitcher
        作者：Arczotis
        邮箱：841530503@qq.com
        """
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "打开 GitHub 并给个 Star")
        alert.addButton(withTitle: firstLaunch ? "开始使用" : "关闭")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.repositoryURL)
        }
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

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
