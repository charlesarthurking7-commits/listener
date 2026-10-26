import Foundation

public enum WAVError: Error, Equatable {
    case notRIFFWave
    case missingChunk(String)
    case unsupportedEncoding(formatTag: UInt16, bitsPerSample: UInt16)
    case truncated
}

/// 16-bit PCM audio as stored in a WAV file. Samples are interleaved when there
/// is more than one channel.
public struct WAVAudio: Equatable, Sendable {
    public let sampleRate: Int
    public let channelCount: Int
    public let samples: [Int16]

    public init(sampleRate: Int, channelCount: Int, samples: [Int16]) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
    }

    public var frameCount: Int { samples.count / channelCount }
}

/// Streams 16-bit mono PCM to disk. The header sizes are patched in `finish()`; until
/// then the header says there is no audio, and WAVReader reads such a file to its end,
/// so a recording survives the app being killed.
public final class WAVWriter {
    private let handle: FileHandle
    private let sampleRate: Int
    private var dataByteCount = 0
    private var finished = false

    public init(url: URL, sampleRate: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        self.sampleRate = sampleRate
        try handle.write(contentsOf: WAVHeader.make(sampleRate: sampleRate, channelCount: 1, dataByteCount: 0))
    }

    public func append(_ samples: [Int16]) throws {
        #if _endian(big)
            let bytes = samples.map(\.littleEndian).withUnsafeBytes { Data($0) }
        #else
            let bytes = samples.withUnsafeBytes { Data($0) }
        #endif
        try handle.write(contentsOf: bytes)
        dataByteCount += bytes.count
    }

    public func finish() throws {
        if finished {
            return
        }
        finished = true
        try handle.seek(toOffset: 0)
        try handle.write(
            contentsOf: WAVHeader.make(sampleRate: sampleRate, channelCount: 1, dataByteCount: dataByteCount))
        try handle.close()
    }

    deinit {
        try? finish()
    }
}

public enum WAVReader {
    public static func read(url: URL) throws -> WAVAudio {
        try parse(Data(contentsOf: url))
    }

    public static func parse(_ data: Data) throws -> WAVAudio {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, ascii(bytes, 0, 4) == "RIFF", ascii(bytes, 8, 4) == "WAVE" else {
            throw WAVError.notRIFFWave
        }

        var format: (tag: UInt16, channels: UInt16, sampleRate: UInt32, bits: UInt16)?
        var offset = 12
        while offset + 8 <= bytes.count {
            let chunkID = ascii(bytes, offset, 4)
            var chunkSize = Int(readUInt32(bytes, offset + 4))
            let body = offset + 8
            if chunkID == "data" && chunkSize == 0 {
                // WAVWriter only fills in the size when it finishes. A recording the app
                // was killed in the middle of still holds everything up to the crash.
                chunkSize = bytes.count - body
            }
            guard body + chunkSize <= bytes.count else {
                throw WAVError.truncated
            }

            if chunkID == "fmt " {
                guard chunkSize >= 16 else {
                    throw WAVError.truncated
                }
                format = (
                    tag: readUInt16(bytes, body),
                    channels: readUInt16(bytes, body + 2),
                    sampleRate: readUInt32(bytes, body + 4),
                    bits: readUInt16(bytes, body + 14)
                )
            } else if chunkID == "data" {
                guard let format else {
                    throw WAVError.missingChunk("fmt ")
                }
                // 0xFFFE is WAVE_FORMAT_EXTENSIBLE, which macOS tools write for plain PCM too.
                guard format.tag == 1 || format.tag == 0xFFFE, format.bits == 16 else {
                    throw WAVError.unsupportedEncoding(formatTag: format.tag, bitsPerSample: format.bits)
                }
                var samples: [Int16] = []
                samples.reserveCapacity(chunkSize / 2)
                var position = body
                while position + 1 < body + chunkSize {
                    samples.append(Int16(bitPattern: readUInt16(bytes, position)))
                    position += 2
                }
                return WAVAudio(
                    sampleRate: Int(format.sampleRate), channelCount: Int(format.channels), samples: samples)
            }

            // Chunks are padded to an even number of bytes.
            offset = body + chunkSize + (chunkSize % 2)
        }
        throw WAVError.missingChunk("data")
    }

    private static func ascii(_ bytes: [UInt8], _ start: Int, _ length: Int) -> String {
        String(decoding: bytes[start..<start + length], as: UTF8.self)
    }

    private static func readUInt16(_ bytes: [UInt8], _ start: Int) -> UInt16 {
        UInt16(bytes[start]) | UInt16(bytes[start + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ start: Int) -> UInt32 {
        UInt32(bytes[start])
            | UInt32(bytes[start + 1]) << 8
            | UInt32(bytes[start + 2]) << 16
            | UInt32(bytes[start + 3]) << 24
    }
}

enum WAVHeader {
    static func make(sampleRate: Int, channelCount: Int, dataByteCount: Int) -> Data {
        let bytesPerFrame = channelCount * 2
        var header = Data(capacity: 44)
        header.append(contentsOf: Array("RIFF".utf8))
        header.appendLittleEndian(UInt32(36 + dataByteCount))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.appendLittleEndian(UInt32(16))
        header.appendLittleEndian(UInt16(1))
        header.appendLittleEndian(UInt16(channelCount))
        header.appendLittleEndian(UInt32(sampleRate))
        header.appendLittleEndian(UInt32(sampleRate * bytesPerFrame))
        header.appendLittleEndian(UInt16(bytesPerFrame))
        header.appendLittleEndian(UInt16(16))
        header.append(contentsOf: Array("data".utf8))
        header.appendLittleEndian(UInt32(dataByteCount))
        return header
    }
}

extension Data {
    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8(value >> 24))
    }
}
