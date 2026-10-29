import Foundation
import XCTest

@testable import pp_friend

final class OggOpusCodecTests: XCTestCase {
  private func sine(sampleRate: Int, seconds: Double) -> Data {
    let count = Int(Double(sampleRate) * seconds)
    var samples = [Int16](repeating: 0, count: count)
    for i in 0..<count {
      let v = sin(2.0 * Double.pi * 440.0 * Double(i) / Double(sampleRate)) * 0.3
      samples[i] = Int16(v * 32767.0)
    }
    return samples.withUnsafeBytes { Data($0) }
  }

  func testEncoderIsAvailable() {
    XCTAssertTrue(OggOpusEncoder.available())
  }

  func testEncodeProducesOggOpus() throws {
    let pcm = sine(sampleRate: 16_000, seconds: 0.3)
    let ogg = try OggOpusEncoder.encode(pcm: pcm, sampleRate: 16_000, channels: 1)

    XCTAssertEqual(Array(ogg.prefix(4)), Array("OggS".utf8))
    XCTAssertNotNil(ogg.range(of: Data("OpusHead".utf8)))
    XCTAssertNotNil(ogg.range(of: Data("OpusTags".utf8)))
  }

  func testRoundTripThroughStreamingDecoder() throws {
    let pcm = sine(sampleRate: 16_000, seconds: 0.3)
    let ogg = try OggOpusEncoder.encode(pcm: pcm, sampleRate: 16_000, channels: 1)

    let decoder = OggOpusDecoder()
    var decoded = Data()
    // 故意用很小的块喂，覆盖跨页、一页多包、lacing 的情况。
    var offset = 0
    while offset < ogg.count {
      let end = min(offset + 37, ogg.count)
      if let chunk = try decoder.feed(ogg.subdata(in: offset..<end)) {
        decoded.append(chunk.pcm16le)
        XCTAssertEqual(chunk.sampleRate, 48_000)
        XCTAssertEqual(chunk.channels, 1)
      }
      offset = end
    }

    let samples = decoded.count / 2
    // 0.3s @48k ≈ 14400，减去 pre-skip（312）后仍应在这个量级。
    XCTAssertGreaterThan(samples, 12_000)
    XCTAssertLessThan(samples, 15_000)
  }

  func testResetThenDecodeAgain() throws {
    let ogg = try OggOpusEncoder.encode(
      pcm: sine(sampleRate: 16_000, seconds: 0.1),
      sampleRate: 16_000,
      channels: 1)

    let decoder = OggOpusDecoder()
    _ = try decoder.feed(ogg.prefix(50))
    decoder.reset()

    let decoded = try decoder.feed(ogg)
    XCTAssertNotNil(decoded)
    XCTAssertGreaterThan(decoded?.pcm16le.count ?? 0, 0)
  }

  func testRejectsUnsupportedSampleRate() {
    XCTAssertThrowsError(
      try OggOpusEncoder.encode(
        pcm: sine(sampleRate: 44_100, seconds: 0.1),
        sampleRate: 44_100,
        channels: 1))
  }
}
