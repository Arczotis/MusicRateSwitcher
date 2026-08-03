import Foundation

public enum NeteaseCacheDecoder {
    public static let xorKey: UInt8 = 0xa3

    public static func decodeHeader(_ encrypted: Data) -> Data {
        Data(encrypted.map { $0 ^ xorKey })
    }

    public static func readFormat(
        at url: URL,
        maximumBytes: Int = 4 * 1_024 * 1_024
    ) throws -> SourceAudioFormat {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let encrypted = try handle.read(upToCount: maximumBytes) ?? Data()
        guard !encrypted.isEmpty else { throw AudioFormatParseError.insufficientData }
        return try EncodedAudioParser.parse(decodeHeader(encrypted))
    }
}
