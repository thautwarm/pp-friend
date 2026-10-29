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

  /// 用 libogg 把整个文件里的 Opus 包按顺序取出来。
  private func packets(in ogg: Data) -> [Data] {
    var sync = ogg_sync_state()
    var stream = ogg_stream_state()
    var page = ogg_page()
    var packet = ogg_packet()
    var inited = false
    var result: [Data] = []

    ogg.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      guard let buf = ogg_sync_buffer(&sync, ogg.count) else { return }
      memcpy(buf, base, ogg.count)
      ogg_sync_wrote(&sync, ogg.count)

      while ogg_sync_pageout(&sync, &page) == 1 {
        if !inited {
          ogg_stream_init(&stream, ogg_page_serialno(&page))
          inited = true
        }
        ogg_stream_pagein(&stream, &page)
        while ogg_stream_packetout(&stream, &packet) == 1 {
          if let ptr = packet.packet, packet.bytes > 0 {
            result.append(Data(bytes: ptr, count: Int(packet.bytes)))
          }
        }
      }
    }
    if inited { ogg_stream_clear(&stream) }
    ogg_sync_clear(&sync)
    return result
  }

  func testOpusTagsIsComplete() throws {
    let ogg = try OggOpusEncoder.encode(
      pcm: sine(sampleRate: 16_000, seconds: 0.1),
      sampleRate: 16_000,
      channels: 1)

    let ps = packets(in: ogg)
    XCTAssertGreaterThanOrEqual(ps.count, 2)
    XCTAssertEqual(String(data: ps[0].prefix(8), encoding: .ascii), "OpusHead")

    let tags = ps[1]
    XCTAssertEqual(String(data: tags.prefix(8), encoding: .ascii), "OpusTags")
    // 8 字节 magic + 4 字节 vendor 长度 + vendor + 4 字节 comment 条数。
    // 少了最后一个字段，整个包就是截断的，严格解析器会拒绝。
    let vendorLen = tags[8..<12].reversed().reduce(0) { $0 << 8 | Int($1) }
    XCTAssertGreaterThan(vendorLen, 0)
    XCTAssertEqual(tags.count, 8 + 4 + vendorLen + 4)
    let countAt = 8 + 4 + vendorLen
    let commentCount = tags[countAt..<(countAt + 4)]
      .reversed().reduce(0) { $0 << 8 | Int($1) }
    XCTAssertEqual(commentCount, 0)
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

  func testDecoderHandlesNewStreamSerial() throws {
    // 每条回复都是一条新的逻辑流（serial 不同）。解码器要能自己切换，
    // 不能一条流用完就永远只认第一个 serial。
    let first = try OggOpusEncoder.encode(
      pcm: sine(sampleRate: 16_000, seconds: 0.2),
      sampleRate: 16_000,
      channels: 1)
    let second = try OggOpusEncoder.encode(
      pcm: sine(sampleRate: 16_000, seconds: 0.2),
      sampleRate: 16_000,
      channels: 1)
    XCTAssertNotEqual(
      Array(first[14..<18]), Array(second[14..<18]),
      "两段测试流的 BOS 页 serial 不应相同")

    let decoder = OggOpusDecoder()
    let decodedFirst = try decoder.feed(first)
    let decodedSecond = try decoder.feed(second)
    XCTAssertGreaterThan(decodedFirst?.pcm16le.count ?? 0, 0)
    XCTAssertGreaterThan(decodedSecond?.pcm16le.count ?? 0, 0)
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
