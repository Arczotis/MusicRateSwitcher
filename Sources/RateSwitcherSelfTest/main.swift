import Foundation
import RateSwitcherCore

enum SelfTestError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        if case .failed(let message) = self { return message }
        return "未知错误"
    }
}

var checks = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    checks += 1
    if !condition() { throw SelfTestError.failed(message) }
}

func makeFLAC(sampleRate: UInt64, bitDepth: UInt64, channels: UInt64, totalSamples: UInt64) -> Data {
    var bytes = Array("fLaC".utf8)
    bytes += [0x80, 0x00, 0x00, 0x22]
    bytes += [0x10, 0x00, 0x10, 0x00]
    bytes += [0, 0, 0, 0, 0, 0]
    let packed = (sampleRate << 44)
        | ((channels - 1) << 41)
        | ((bitDepth - 1) << 36)
        | (totalSamples & 0x0000_000f_ffff_ffff)
    bytes += (0..<8).reversed().map { UInt8((packed >> UInt64($0 * 8)) & 0xff) }
    bytes += [UInt8](repeating: 0, count: 16)
    return Data(bytes)
}

func le16(_ value: UInt16) -> [UInt8] {
    [UInt8(value & 0xff), UInt8(value >> 8)]
}

func le32(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]
}

func be16(_ value: UInt16) -> [UInt8] {
    [UInt8(value >> 8), UInt8(value & 0xff)]
}

func be32(_ value: UInt32) -> [UInt8] {
    [UInt8(value >> 24), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}

do {
    if let option = CommandLine.arguments.firstIndex(of: "--parse-file"), option + 1 < CommandLine.arguments.count {
        let url = URL(fileURLWithPath: CommandLine.arguments[option + 1])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
        let format = try EncodedAudioParser.parse(data)
        print("PARSED_FORMAT: \(format)")
        exit(0)
    }

    if let option = CommandLine.arguments.firstIndex(of: "--probe-player"), option + 1 < CommandLine.arguments.count {
        let name = CommandLine.arguments[option + 1]
        let source: SampleRateSource
        switch name {
        case "qq": source = QQMusicPlaybackMonitor()
        case "soda": source = SodaPlaybackMonitor()
        default: throw SelfTestError.failed("--probe-player 仅支持 qq 或 soda")
        }
        var detected: DetectedSourceFormat?
        source.onStateChanged = { print("SOURCE_STATE: \($0)") }
        source.onFormatChanged = {
            detected = $0
            print("SOURCE_FORMAT: \($0.format.description) [\($0.identifier ?? "-")]")
        }
        source.start()
        let deadline = Date().addingTimeInterval(7)
        while detected == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        print("ACTIVITY_PIDS: \(source.activityProcessIDs.map(String.init).joined(separator: ","))")
        source.stop()
        guard detected != nil else { throw SelfTestError.failed("\(name) 未检测到当前音频格式") }
        exit(0)
    }

    if let option = CommandLine.arguments.firstIndex(of: "--set-rate"), option + 1 < CommandLine.arguments.count,
       let requestedRate = Double(CommandLine.arguments[option + 1]) {
        let audio = CoreAudioController()
        var finished = false
        var succeeded = false
        audio.switchSampleRate(sourceRate: requestedRate, deviceUID: nil) { result in
            print("SWITCH_RESULT: \(result)")
            if case .failed = result { succeeded = false } else { succeeded = true }
            finished = true
        }
        let deadline = Date().addingTimeInterval(4)
        while !finished, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        try check(finished && succeeded, "Core Audio 采样率切换失败或超时")
    }

    if CommandLine.arguments.contains("--devices") {
        let audio = CoreAudioController()
        for device in audio.outputDevices() {
            let marker = device.isDefault ? "*" : " "
            let rates = device.supportedRates.map(SourceAudioFormat.formatRate).joined(separator: ", ")
            print("\(marker) \(device.name) [\(device.uid)] current=\(SourceAudioFormat.formatRate(device.sampleRate)) supported=\(rates)")
        }
    }

    if let option = CommandLine.arguments.firstIndex(of: "--activity"), option + 1 < CommandLine.arguments.count,
       let pid = pid_t(CommandLine.arguments[option + 1]) {
        let audio = CoreAudioController()
        print("AUDIO_OUTPUT_ACTIVE: \(audio.isProcessProducingOutput(pid))")
    }

    let flac = makeFLAC(sampleRate: 96_000, bitDepth: 24, channels: 2, totalSamples: 9_600_000)
    let flacFormat = try EncodedAudioParser.parse(flac)
    try check(flacFormat.sampleRate == 96_000, "FLAC 采样率解析失败")
    try check(flacFormat.bitDepth == 24, "FLAC 位深解析失败")
    try check(flacFormat.channels == 2, "FLAC 声道解析失败")
    try check(abs((flacFormat.duration ?? 0) - 100) < 0.001, "FLAC 时长解析失败")

    let encrypted = Data(flac.map { $0 ^ NeteaseCacheDecoder.xorKey })
    try check(NeteaseCacheDecoder.decodeHeader(encrypted) == flac, "网易云 XOR 解码失败")

    var mp3 = Array("ID3".utf8) + [4, 0, 0, 0, 0, 0, 4] + [0, 0, 0, 0]
    mp3 += [0xff, 0xfb, 0xb0, 0x00, 0, 0, 0, 0]
    let mp3Format = try EncodedAudioParser.parse(Data(mp3))
    try check(mp3Format.sampleRate == 44_100, "MP3 采样率解析失败")
    try check(mp3Format.codec == "MP3", "MP3 编码识别失败")

    let adtsFormat = try EncodedAudioParser.parse(Data([0xff, 0xf1, 0x4c, 0x80, 0, 0, 0]))
    try check(adtsFormat.sampleRate == 48_000, "AAC 采样率解析失败")
    try check(adtsFormat.channels == 2, "AAC 声道解析失败")

    var encryptedMP4 = be32(16) + Array("ftyp".utf8) + Array("M4A ".utf8) + [0xff, 0xfb, 0, 0]
    encryptedMP4 += be32(36) + Array("enca".utf8) + [UInt8](repeating: 0, count: 16)
    encryptedMP4 += be16(2) + be16(16) + [0, 0, 0, 0] + be32(48_000 << 16)
    let encryptedMP4Format = try EncodedAudioParser.parse(Data(encryptedMP4))
    try check(encryptedMP4Format.sampleRate == 48_000, "汽水 CENC MP4 采样率解析失败")
    try check(encryptedMP4Format.codec == "AAC (CENC)", "汽水 CENC MP4 编码识别失败")

    let qqMetadataJSON = Data(#"{"data":[{"title":"测试曲目","file":{"hires_sample":96000,"hires_bitdepth":"24"}}]}"#.utf8)
    let qqMetadata = QQMusicSongMetadataParser.parse(qqMetadataJSON)
    try check(qqMetadata?.sampleRate == 96_000, "QQ 音乐 Hi-Res 采样率解析失败")
    try check(qqMetadata?.bitDepth == 24, "QQ 音乐 Hi-Res 位深解析失败")
    try check(
        QQMusicPlaybackMonitor.songID(from: URL(fileURLWithPath: "/tmp/102366219-13.mgg")) == "102366219",
        "QQ 音乐缓存歌曲 ID 解析失败"
    )

    var wave = Array("RIFF".utf8) + le32(36) + Array("WAVEfmt ".utf8) + le32(16)
    wave += le16(1) + le16(2) + le32(88_200) + le32(0) + le16(0) + le16(24)
    let waveFormat = try EncodedAudioParser.parse(Data(wave))
    try check(waveFormat.sampleRate == 88_200, "WAVE 采样率解析失败")
    try check(waveFormat.bitDepth == 24, "WAVE 位深解析失败")

    try check(
        SampleRateMatcher.bestRate(for: 176_400, supported: [44_100, 48_000, 88_200, 96_000]) == 88_200,
        "44.1 kHz 家族回退失败"
    )
    try check(
        SampleRateMatcher.bestRate(for: 192_000, supported: [44_100, 48_000, 88_200, 96_000]) == 96_000,
        "48 kHz 家族回退失败"
    )

    let applePlaybackLog = "play> cm>> mediaFormatinfo = '<private>', sdFormatID = alac, sdBitDepth = 24 bit, asbdSampleRate = 192 kHz"
    let applePlayback = AppleMusicLogParser.parse(message: applePlaybackLog)
    try check(applePlayback?.format.sampleRate == 192_000, "Apple Music 播放日志采样率解析失败")
    try check(applePlayback?.format.bitDepth == 24, "Apple Music 播放日志位深解析失败")
    try check(applePlayback?.confidence == .activePlayback, "Apple Music 播放日志置信度错误")

    let appleDecoderLog = "ACAppleLosslessDecoder.cpp: Input format: 2 ch, 88200 Hz, from 24-bit source"
    let appleDecoder = AppleMusicLogParser.parse(message: appleDecoderLog)
    try check(appleDecoder?.format.sampleRate == 88_200, "Apple Music 解码日志采样率解析失败")
    try check(appleDecoder?.format.channels == 2, "Apple Music 解码日志声道解析失败")
    try check(appleDecoder?.confidence == .decoderFallback, "Apple Music 解码日志置信度错误")

    let lossyLog = "play> cm>> sdFormatID = aac, sdBitDepth = 16 bit, asbdSampleRate = 48 kHz"
    try check(AppleMusicLogParser.parse(message: lossyLog) == nil, "Apple Music 有损占位日志不应触发切换")

    let earlier = Date(timeIntervalSince1970: 100)
    let later = Date(timeIntervalSince1970: 200)
    let appleDetection = DetectedSourceFormat(
        player: .appleMusic,
        format: SourceAudioFormat(sampleRate: 88_200, bitDepth: 24, channels: 2, codec: "ALAC"),
        detectedAt: earlier
    )
    let neteaseDetection = DetectedSourceFormat(
        player: .neteaseMusic,
        format: SourceAudioFormat(sampleRate: 96_000, bitDepth: 24, channels: 2, codec: "FLAC"),
        detectedAt: later
    )
    let bothPlayers = Set(MusicPlayerID.allCases)
    try check(
        PlaybackArbitrator.preferredDetection(
            from: [appleDetection, neteaseDetection],
            enabledPlayers: bothPlayers,
            outputActivity: [.appleMusic: true, .neteaseMusic: false],
            activitySupported: true
        )?.player == .appleMusic,
        "暂停播放器不应抢占正在输出的播放器"
    )
    try check(
        PlaybackArbitrator.preferredDetection(
            from: [appleDetection, neteaseDetection],
            enabledPlayers: bothPlayers,
            outputActivity: [.appleMusic: true, .neteaseMusic: true],
            activitySupported: true
        )?.player == .neteaseMusic,
        "多个播放器输出时应采用最近数据"
    )
    try check(
        PlaybackArbitrator.preferredDetection(
            from: [appleDetection, neteaseDetection],
            enabledPlayers: bothPlayers,
            outputActivity: [.appleMusic: false, .neteaseMusic: false],
            activitySupported: true
        ) == nil,
        "没有播放器输出时不应驱动采样率"
    )
    try check(
        PlaybackArbitrator.preferredDetection(
            from: [appleDetection, neteaseDetection],
            enabledPlayers: bothPlayers,
            outputActivity: [:],
            activitySupported: false
        )?.player == .neteaseMusic,
        "旧系统应回退到最近数据源"
    )

    print("PASS: \(checks) checks")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
