import Foundation

public enum EncodedAudioParser {
    public static func parse(_ data: Data) throws -> SourceAudioFormat {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw AudioFormatParseError.insufficientData }

        if bytes.starts(with: Array("fLaC".utf8)) {
            return try parseFLAC(bytes)
        }
        if bytes.starts(with: Array("RIFF".utf8)) && bytes.count >= 12 && bytes[8..<12].elementsEqual("WAVE".utf8) {
            return try parseWAVE(bytes)
        }
        if bytes.starts(with: Array("FORM".utf8)) && bytes.count >= 12 {
            return try parseAIFF(bytes)
        }
        if bytes.count >= 12 && bytes[4..<8].elementsEqual("ftyp".utf8) {
            return try parseMP4(bytes)
        }
        if bytes.starts(with: Array("ID3".utf8)) || findMP3Frame(in: bytes, startingAt: 0) != nil {
            return try parseMP3(bytes)
        }
        if findADTSFrame(in: bytes) != nil {
            return try parseADTS(bytes)
        }
        throw AudioFormatParseError.unsupportedFormat
    }

    private static func parseFLAC(_ bytes: [UInt8]) throws -> SourceAudioFormat {
        var cursor = 4
        while cursor + 4 <= bytes.count {
            let blockHeader = bytes[cursor]
            let type = blockHeader & 0x7f
            let isLast = blockHeader & 0x80 != 0
            let length = Int(bytes[cursor + 1]) << 16 | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
            let body = cursor + 4
            guard body + length <= bytes.count else { throw AudioFormatParseError.insufficientData }

            if type == 0 {
                guard length >= 34, body + 18 <= bytes.count else {
                    throw AudioFormatParseError.malformed("FLAC STREAMINFO 长度错误")
                }
                let packed = readUInt64BE(bytes, at: body + 10)
                let sampleRate = Double((packed >> 44) & 0x000f_ffff)
                let channels = Int((packed >> 41) & 0x7) + 1
                let bitDepth = Int((packed >> 36) & 0x1f) + 1
                let totalSamples = packed & 0x0000_000f_ffff_ffff
                guard validSampleRate(sampleRate) else {
                    throw AudioFormatParseError.malformed("FLAC 采样率无效")
                }
                let duration = totalSamples > 0 ? Double(totalSamples) / sampleRate : nil
                return SourceAudioFormat(
                    sampleRate: sampleRate,
                    bitDepth: bitDepth,
                    channels: channels,
                    codec: "FLAC",
                    duration: duration
                )
            }

            cursor = body + length
            if isLast { break }
        }
        throw AudioFormatParseError.malformed("缺少 FLAC STREAMINFO")
    }

    private static func parseMP3(_ bytes: [UInt8]) throws -> SourceAudioFormat {
        var start = 0
        if bytes.count >= 10, bytes.starts(with: Array("ID3".utf8)) {
            let size = synchsafeInt(bytes[6], bytes[7], bytes[8], bytes[9])
            start = min(bytes.count, 10 + size)
        }

        guard let index = findMP3Frame(in: bytes, startingAt: start), index + 4 <= bytes.count else {
            throw AudioFormatParseError.insufficientData
        }
        let b1 = bytes[index + 1]
        let b2 = bytes[index + 2]
        let b3 = bytes[index + 3]
        let versionBits = (b1 >> 3) & 0x3
        let sampleIndex = Int((b2 >> 2) & 0x3)
        guard sampleIndex < 3 else { throw AudioFormatParseError.malformed("MP3 采样率索引无效") }

        let base = [44_100.0, 48_000.0, 32_000.0][sampleIndex]
        let sampleRate: Double
        switch versionBits {
        case 0b11: sampleRate = base
        case 0b10: sampleRate = base / 2
        case 0b00: sampleRate = base / 4
        default: throw AudioFormatParseError.malformed("保留的 MPEG 版本")
        }
        let channelMode = (b3 >> 6) & 0x3
        return SourceAudioFormat(
            sampleRate: sampleRate,
            channels: channelMode == 0b11 ? 1 : 2,
            codec: "MP3"
        )
    }

    private static func parseADTS(_ bytes: [UInt8]) throws -> SourceAudioFormat {
        guard let index = findADTSFrame(in: bytes), index + 7 <= bytes.count else {
            throw AudioFormatParseError.insufficientData
        }
        let frequencyIndex = Int((bytes[index + 2] >> 2) & 0x0f)
        let rates = [
            96_000.0, 88_200.0, 64_000.0, 48_000.0, 44_100.0, 32_000.0,
            24_000.0, 22_050.0, 16_000.0, 12_000.0, 11_025.0, 8_000.0, 7_350.0
        ]
        guard frequencyIndex < rates.count else {
            throw AudioFormatParseError.malformed("AAC 采样率索引无效")
        }
        let channelConfig = Int((bytes[index + 2] & 0x1) << 2 | (bytes[index + 3] >> 6))
        return SourceAudioFormat(
            sampleRate: rates[frequencyIndex],
            channels: channelConfig == 0 ? nil : channelConfig,
            codec: "AAC"
        )
    }

    private static func parseMP4(_ bytes: [UInt8]) throws -> SourceAudioFormat {
        let sampleEntries: [(String, [UInt8])] = [
            ("ALAC", Array("alac".utf8)),
            ("AAC", Array("mp4a".utf8)),
            ("AAC (CENC)", Array("enca".utf8))
        ]

        for (codec, marker) in sampleEntries {
            guard bytes.count >= marker.count else { continue }
            for index in 4...(bytes.count - marker.count) where bytes[index..<(index + 4)].elementsEqual(marker) {
                let boxStart = index - 4
                guard boxStart + 36 <= bytes.count else { continue }
                let boxSize = Int(readUInt32BE(bytes, at: boxStart))
                guard boxSize >= 36, boxStart + boxSize <= bytes.count else { continue }
                let channels = Int(readUInt16BE(bytes, at: boxStart + 24))
                let bitDepth = Int(readUInt16BE(bytes, at: boxStart + 26))
                let fixedRate = readUInt32BE(bytes, at: boxStart + 32)
                let sampleRate = Double(fixedRate >> 16) + Double(fixedRate & 0xffff) / 65_536.0
                guard validSampleRate(sampleRate), (1...32).contains(channels) else { continue }
                return SourceAudioFormat(
                    sampleRate: sampleRate,
                    bitDepth: bitDepth > 0 ? bitDepth : nil,
                    channels: channels,
                    codec: codec
                )
            }
        }
        throw AudioFormatParseError.insufficientData
    }

    private static func parseWAVE(_ bytes: [UInt8]) throws -> SourceAudioFormat {
        var cursor = 12
        while cursor + 8 <= bytes.count {
            let id = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii)
            let length = Int(readUInt32LE(bytes, at: cursor + 4))
            let body = cursor + 8
            if id == "fmt " {
                guard length >= 16, body + 16 <= bytes.count else { throw AudioFormatParseError.insufficientData }
                let formatCode = readUInt16LE(bytes, at: body)
                let channels = Int(readUInt16LE(bytes, at: body + 2))
                let sampleRate = Double(readUInt32LE(bytes, at: body + 4))
                let bitDepth = Int(readUInt16LE(bytes, at: body + 14))
                guard validSampleRate(sampleRate) else { throw AudioFormatParseError.malformed("WAVE 采样率无效") }
                let codec = formatCode == 3 ? "WAVE Float" : "WAVE PCM"
                return SourceAudioFormat(sampleRate: sampleRate, bitDepth: bitDepth, channels: channels, codec: codec)
            }
            cursor = body + length + (length & 1)
        }
        throw AudioFormatParseError.insufficientData
    }

    private static func parseAIFF(_ bytes: [UInt8]) throws -> SourceAudioFormat {
        var cursor = 12
        while cursor + 8 <= bytes.count {
            let id = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii)
            let length = Int(readUInt32BE(bytes, at: cursor + 4))
            let body = cursor + 8
            if id == "COMM" {
                guard length >= 18, body + 18 <= bytes.count else { throw AudioFormatParseError.insufficientData }
                let channels = Int(readUInt16BE(bytes, at: body))
                let bitDepth = Int(readUInt16BE(bytes, at: body + 6))
                let sampleRate = decodeExtended80(bytes, at: body + 8)
                guard validSampleRate(sampleRate) else { throw AudioFormatParseError.malformed("AIFF 采样率无效") }
                return SourceAudioFormat(sampleRate: sampleRate, bitDepth: bitDepth, channels: channels, codec: "AIFF")
            }
            cursor = body + length + (length & 1)
        }
        throw AudioFormatParseError.insufficientData
    }

    private static func findMP3Frame(in bytes: [UInt8], startingAt start: Int) -> Int? {
        guard bytes.count >= 4, start < bytes.count - 3 else { return nil }
        let end = min(bytes.count - 3, start + 2_000_000)
        for index in max(0, start)..<end {
            guard bytes[index] == 0xff, bytes[index + 1] & 0xe0 == 0xe0 else { continue }
            let version = (bytes[index + 1] >> 3) & 0x3
            let layer = (bytes[index + 1] >> 1) & 0x3
            let bitrateIndex = (bytes[index + 2] >> 4) & 0xf
            let sampleIndex = (bytes[index + 2] >> 2) & 0x3
            if version != 0b01, layer != 0, bitrateIndex != 0, bitrateIndex != 0xf, sampleIndex != 0x3 {
                return index
            }
        }
        return nil
    }

    private static func findADTSFrame(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 7 else { return nil }
        let end = min(bytes.count - 6, 2_000_000)
        for index in 0..<end where bytes[index] == 0xff && bytes[index + 1] & 0xf6 == 0xf0 {
            return index
        }
        return nil
    }

    private static func synchsafeInt(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
        Int(a & 0x7f) << 21 | Int(b & 0x7f) << 14 | Int(c & 0x7f) << 7 | Int(d & 0x7f)
    }

    private static func validSampleRate(_ value: Double) -> Bool {
        value >= 7_000 && value <= 768_000
    }

    private static func readUInt16BE(_ b: [UInt8], at i: Int) -> UInt16 {
        UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }

    private static func readUInt16LE(_ b: [UInt8], at i: Int) -> UInt16 {
        UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func readUInt32BE(_ b: [UInt8], at i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func readUInt32LE(_ b: [UInt8], at i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static func readUInt64BE(_ b: [UInt8], at i: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in b[i..<(i + 8)] { value = value << 8 | UInt64(byte) }
        return value
    }

    private static func decodeExtended80(_ b: [UInt8], at i: Int) -> Double {
        let exponentRaw = Int(readUInt16BE(b, at: i))
        if exponentRaw == 0 { return 0 }
        let sign = exponentRaw & 0x8000 == 0 ? 1.0 : -1.0
        let exponent = (exponentRaw & 0x7fff) - 16_383
        let mantissa = readUInt64BE(b, at: i + 2)
        return sign * Double(mantissa) * pow(2.0, Double(exponent - 63))
    }
}
