import Foundation

public enum AppleMusicLogConfidence: Int, Sendable {
    case decoderFallback = 1
    case activePlayback = 2
}

public struct AppleMusicLogObservation: Equatable, Sendable {
    public let format: SourceAudioFormat
    public let confidence: AppleMusicLogConfidence
    public let trackIdentifier: String?

    public init(
        format: SourceAudioFormat,
        confidence: AppleMusicLogConfidence,
        trackIdentifier: String? = nil
    ) {
        self.format = format
        self.confidence = confidence
        self.trackIdentifier = trackIdentifier
    }
}

public enum AppleMusicLogParser {
    public static func parse(message: String) -> AppleMusicLogObservation? {
        if message.contains("play> cm>>") || message.contains("audioCapabilities:") {
            return parsePlaybackMessage(message)
        }
        if message.contains("ACAppleLosslessDecoder.cpp"), message.contains("Input format:") {
            return parseDecoderMessage(message)
        }
        return nil
    }

    private static func parsePlaybackMessage(_ message: String) -> AppleMusicLogObservation? {
        guard let formatID = capture(#"sdFormatID\s*=\s*([A-Za-z0-9]+)"#, in: message)?.lowercased(),
              formatID == "alac",
              let rateText = capture(#"asbdSampleRate\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*kHz"#, in: message),
              let rateKHz = Double(rateText)
        else { return nil }

        let bitDepth = capture(#"sdBitDepth\s*=\s*([0-9]+)\s*bit"#, in: message).flatMap(Int.init)
        var identifier = capture(#"mediaFormatinfo\s*=\s*'([^']+)'"#, in: message)
        if identifier == "<private>" { identifier = nil }
        return AppleMusicLogObservation(
            format: SourceAudioFormat(
                sampleRate: rateKHz * 1_000,
                bitDepth: bitDepth,
                channels: 2,
                codec: "ALAC"
            ),
            confidence: .activePlayback,
            trackIdentifier: identifier
        )
    }

    private static func parseDecoderMessage(_ message: String) -> AppleMusicLogObservation? {
        guard
            let channelsText = capture(#"([0-9]+)\s*ch,\s*([0-9]+(?:\.[0-9]+)?)\s*Hz"#, in: message, group: 1),
            let rateText = capture(#"([0-9]+)\s*ch,\s*([0-9]+(?:\.[0-9]+)?)\s*Hz"#, in: message, group: 2),
            let channels = Int(channelsText),
            let rate = Double(rateText)
        else { return nil }
        let bitDepth = capture(#"from\s+([0-9]+)-bit source"#, in: message).flatMap(Int.init)
        return AppleMusicLogObservation(
            format: SourceAudioFormat(
                sampleRate: rate,
                bitDepth: bitDepth,
                channels: channels,
                codec: "ALAC"
            ),
            confidence: .decoderFallback
        )
    }

    private static func capture(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              group < match.numberOfRanges,
              let swiftRange = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[swiftRange])
    }
}
