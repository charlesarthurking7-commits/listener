import Foundation
import Testing

@testable import ListenerCore

struct WAVFileTests {
    @Test func writtenFileReadsBackIdentically() throws {
        let url = temporaryFile("roundtrip.wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let first: [Int16] = [0, 1, -1, Int16.max, Int16.min]
        let second: [Int16] = [42, -42]
        let writer = try WAVWriter(url: url, sampleRate: 16_000)
        try writer.append(first)
        try writer.append(second)
        try writer.finish()

        let audio = try WAVReader.read(url: url)
        #expect(audio.sampleRate == 16_000)
        #expect(audio.channelCount == 1)
        #expect(audio.samples == first + second)

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 44 + 7 * 2)
    }

    @Test func headerMatchesCanonicalLayout() {
        let header = [UInt8](WAVHeader.make(sampleRate: 16_000, channelCount: 1, dataByteCount: 32_000))
        #expect(header.count == 44)
        #expect(Array(header[0..<4]) == Array("RIFF".utf8))
        #expect(Array(header[4..<8]) == [0x24, 0x7D, 0x00, 0x00])
        #expect(Array(header[24..<28]) == [0x80, 0x3E, 0x00, 0x00])
        #expect(Array(header[28..<32]) == [0x00, 0x7D, 0x00, 0x00])
        #expect(Array(header[40..<44]) == [0x00, 0x7D, 0x00, 0x00])
    }

    @Test func readerSkipsUnknownChunksAndPadding() throws {
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(0))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("LIST".utf8))
        data.appendLittleEndian(UInt32(3))
        data.append(contentsOf: [1, 2, 3, 0])
        let header = WAVHeader.make(sampleRate: 48_000, channelCount: 2, dataByteCount: 8)
        data.append(header[12...])
        for sample: Int16 in [10, -10, 20, -20] {
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }

        let audio = try WAVReader.parse(data)
        #expect(audio.sampleRate == 48_000)
        #expect(audio.channelCount == 2)
        #expect(audio.frameCount == 2)
        #expect(audio.channel(0) == [10, 20])
        #expect(audio.channel(1) == [-10, -20])
    }

    @Test func readerRejectsNonPCMAndGarbage() {
        #expect(throws: WAVError.notRIFFWave) {
            try WAVReader.parse(Data("not a wav file".utf8))
        }

        var floatHeader = WAVHeader.make(sampleRate: 16_000, channelCount: 1, dataByteCount: 0)
        floatHeader[34] = 32
        #expect(throws: WAVError.unsupportedEncoding(formatTag: 1, bitsPerSample: 32)) {
            try WAVReader.parse(floatHeader)
        }
    }

    @Test func readerReportsTruncatedData() {
        var data = WAVHeader.make(sampleRate: 16_000, channelCount: 1, dataByteCount: 100)
        data.append(contentsOf: [0, 0])
        #expect(throws: WAVError.truncated) {
            try WAVReader.parse(data)
        }
    }
}

func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("listener-tests-\(UUID().uuidString)-\(name)")
}
