import Foundation

public struct SourceAudioFormat: Equatable, Sendable, CustomStringConvertible {
    public let sampleRate: Double
    public let bitDepth: Int?
    public let channels: Int?
    public let codec: String
    public let duration: Double?

    public init(
        sampleRate: Double,
        bitDepth: Int? = nil,
        channels: Int? = nil,
        codec: String,
        duration: Double? = nil
    ) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.codec = codec
        self.duration = duration
    }

    public var description: String {
        var parts = [Self.formatRate(sampleRate)]
        if let bitDepth { parts.append("\(bitDepth)-bit") }
        if let channels { parts.append("\(channels) ch") }
        parts.append(codec)
        return parts.joined(separator: " / ")
    }

    public static func formatRate(_ rate: Double) -> String {
        let kHz = rate / 1_000
        if abs(kHz.rounded() - kHz) < 0.001 {
            return String(format: "%.0f kHz", kHz)
        }
        return String(format: "%.1f kHz", kHz)
    }
}

public enum AudioFormatParseError: LocalizedError, Equatable {
    case insufficientData
    case unsupportedFormat
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .insufficientData:
            return "音频头数据不足"
        case .unsupportedFormat:
            return "暂不支持这种音频格式"
        case .malformed(let reason):
            return "音频头格式异常：\(reason)"
        }
    }
}
