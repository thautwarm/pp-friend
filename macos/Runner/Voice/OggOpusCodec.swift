import Foundation

/// 解码出来的一块 PCM。
struct DecodedPcm {
  let pcm16le: Data
  let sampleRate: Int
  let channels: Int

  var map: [String: Any] {
    ["pcm": pcm16le, "sampleRate": sampleRate, "channels": channels]
  }
}

enum OggOpusError: LocalizedError {
  case badHeader(String)
  case opus(String)
  case ogg(String)

  var errorDescription: String? {
    switch self {
    case .badHeader(let m): return "Ogg Opus 头不对：\(m)"
    case .opus(let m): return "Opus 错误：\(m)"
    case .ogg(let m): return "Ogg 错误：\(m)"
    }
  }
}

/// 连续 Ogg Opus 流的增量解码器。
///
/// 和 Android 的 `StreamingOggDecoder` 同一套语义：允许包跨页、一页多包，
/// 第一次见到 OpusHead 才建解码器；reset 之后必须能从新的 OpusHead 重新开始。
/// 所有调用必须在同一个串行队列上（插件层负责）。
final class OggOpusDecoder {
  private var syncState = ogg_sync_state()
  private var streamState = ogg_stream_state()
  private var streamInited = false
  private var serial: Int32 = 0
  private var decoder: OpaquePointer?
  private var channels = 1
  private var preSkip = 0
  private var skipped = 0
  private var packetIndex = 0
  private var sawHeaders = false

  deinit { reset() }

  func reset() {
    if let decoder {
      opus_decoder_destroy(decoder)
      self.decoder = nil
    }
    if streamInited {
      ogg_stream_clear(&streamState)
      streamInited = false
    }
    ogg_sync_clear(&syncState)
    syncState = ogg_sync_state()
    streamState = ogg_stream_state()
    serial = 0
    channels = 1
    preSkip = 0
    skipped = 0
    packetIndex = 0
    sawHeaders = false
  }

  /// 喂一块字节，返回这次解出来的 PCM（没有完整包就返回 nil）。
  func feed(_ data: Data) throws -> DecodedPcm? {
    var output = Data()
    var failure: Error?

    data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      var offset = 0
      while offset < data.count && failure == nil {
        let chunk = min(4096, data.count - offset)
        guard let buf = ogg_sync_buffer(&syncState, chunk) else {
          failure = OggOpusError.ogg("ogg_sync_buffer 返回空")
          return
        }
        memcpy(buf, base.advanced(by: offset), chunk)
        ogg_sync_wrote(&syncState, chunk)
        offset += chunk

        while true {
          var page = ogg_page()
          let got = ogg_sync_pageout(&syncState, &page)
          if got == 0 { break }
          if got < 0 { continue }  // 坏页/hole：跳过，让后面的包继续
          do {
            try processPage(&page, output: &output)
          } catch {
            failure = error
            return
          }
        }
      }
    }

    if let failure { throw failure }
    guard !output.isEmpty else { return nil }
    return DecodedPcm(pcm16le: output, sampleRate: 48_000, channels: channels)
  }

  func finish() throws -> DecodedPcm? {
    // 这条回复结束：下一条回复可能复用同一个 serial，也可能换一个。
    // 不清理的话，旧的 packet 序号/granule 会带进下一条流。
    reset()
    return nil
  }

  private func processPage(_ page: inout ogg_page, output: inout Data) throws {
    let pageSerial = Int32(ogg_page_serialno(&page))

    // 每条回复是一条独立的逻辑流，serial 不同。以前的实现只在第一次
    // init，第二条回复开始 pagein 就失败（"ogg_stream_pagein 失败"）。
    if streamInited && pageSerial != serial {
      ogg_stream_clear(&streamState)
      streamInited = false
      if let decoder {
        opus_decoder_destroy(decoder)
        self.decoder = nil
      }
      channels = 1
      preSkip = 0
      skipped = 0
      packetIndex = 0
      sawHeaders = false
    }

    if !streamInited {
      guard ogg_stream_init(&streamState, pageSerial) == 0 else {
        throw OggOpusError.ogg("ogg_stream_init 失败")
      }
      serial = pageSerial
      streamInited = true
    }
    guard ogg_stream_pagein(&streamState, &page) == 0 else {
      throw OggOpusError.ogg("ogg_stream_pagein 失败")
    }

    var packet = ogg_packet()
    while ogg_stream_packetout(&streamState, &packet) == 1 {
      defer { packetIndex += 1 }
      if !sawHeaders {
        try parseHeaders(packet, output: &output)
        continue
      }
      try decode(packet, output: &output)
    }
  }

  private func parseHeaders(_ packet: ogg_packet, output: inout Data) throws {
    guard let bytes = packet.packet else {
      throw OggOpusError.badHeader("空包")
    }
    let count = Int(packet.bytes)
    if packetIndex == 0 {
      guard count >= 19 else { throw OggOpusError.badHeader("OpusHead 太短") }
      let head = UnsafeBufferPointer(start: bytes, count: count)
      guard String(bytes: head[0..<8], encoding: .ascii) == "OpusHead" else {
        throw OggOpusError.badHeader("缺 OpusHead")
      }
      let ch = Int(head[9])
      // pre-skip 是 48kHz 下的采样数（LE UInt16）。
      preSkip = Int(head[10]) | (Int(head[11]) << 8)
      var err: Int32 = 0
      decoder = opus_decoder_create(48_000, Int32(ch), &err)
      guard err == OPUS_OK, decoder != nil else {
        throw OggOpusError.opus("opus_decoder_create 失败：\(err)")
      }
      channels = ch
      skipped = 0
      return
    }
    if packetIndex == 1 {
      let tags = UnsafeBufferPointer(start: bytes, count: count)
      let isTags =
        count >= 8
        && String(bytes: tags[0..<8], encoding: .ascii) == "OpusTags"
      if isTags {
        sawHeaders = true
        return
      }
    }
    // 没有 OpusTags 的流（不合规但存在）：直接当音频处理。
    sawHeaders = true
    try decode(packet, output: &output)
  }

  private func decode(_ packet: ogg_packet, output: inout Data) throws {
    guard let decoder else { throw OggOpusError.badHeader("还没见到 OpusHead") }
    guard let ptr = packet.packet, packet.bytes > 0 else { return }

    let maxSamples = 5760  // 120ms @ 48k，Opus 允许的最大帧
    var pcm = [Int16](repeating: 0, count: maxSamples * channels)
    let decoded: Int32 = pcm.withUnsafeMutableBufferPointer { out -> Int32 in
      guard let base = out.baseAddress else { return -1 }
      return opus_decode(
        decoder,
        ptr,
        Int32(packet.bytes),
        base,
        Int32(maxSamples),
        0
      )
    }
    guard decoded >= 0 else {
      throw OggOpusError.opus("opus_decode 失败：\(decoded)")
    }

    let frames = Int(decoded)
    var start = 0
    if skipped < preSkip {
      let drop = min(preSkip - skipped, frames)
      skipped += drop
      start = drop
    }
    let usable = frames - start
    guard usable > 0 else { return }

    let offset = start * channels
    let byteCount = usable * channels * MemoryLayout<Int16>.size
    pcm.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      output.append(Data(bytes: base.advanced(by: offset * 2), count: byteCount))
    }
  }
}

/// 把 PCM16LE 编码成独立的 Ogg Opus 文件（上行用）。
enum OggOpusEncoder {
  /// Opus 的编码器 lookahead，48kHz 下是 312 个采样；写进 OpusHead 的
  /// pre-skip，解码端会据此丢掉开头的静音。
  static let preSkip = 312

  static func available() -> Bool {
    var err: Int32 = 0
    guard let enc = opus_encoder_create(48_000, 1, OPUS_APPLICATION_VOIP, &err) else {
      return false
    }
    opus_encoder_destroy(enc)
    return err == OPUS_OK
  }

  static func encode(pcm: Data, sampleRate: Int, channels: Int) throws -> Data {
    let supported = [8_000, 12_000, 16_000, 24_000, 48_000]
    guard supported.contains(sampleRate) else {
      throw OggOpusError.opus("不支持的采样率 \(sampleRate)")
    }
    guard channels == 1 else {
      throw OggOpusError.opus("目前只支持单声道")
    }

    let count = pcm.count / 2
    var samples = [Int16](repeating: 0, count: count)
    samples.withUnsafeMutableBytes { dst in
      pcm.copyBytes(to: dst, count: count * 2)
    }
    guard !samples.isEmpty else {
      throw OggOpusError.opus("空 PCM")
    }

    var err: Int32 = 0
    guard
      let encoder = opus_encoder_create(
        Int32(sampleRate), Int32(channels), OPUS_APPLICATION_VOIP, &err)
    else {
      throw OggOpusError.opus("opus_encoder_create 失败：\(err)")
    }
    defer { opus_encoder_destroy(encoder) }
    guard err == OPUS_OK else {
      throw OggOpusError.opus("opus_encoder_create 失败：\(err)")
    }

    let frameSamples = sampleRate / 50  // 20ms
    var packets: [Data] = []
    var index = 0
    while index < samples.count {
      var frame = Array(samples[index..<min(index + frameSamples, samples.count)])
      if frame.count < frameSamples {
        frame.append(contentsOf: [Int16](repeating: 0, count: frameSamples - frame.count))
      }

      var out = [UInt8](repeating: 0, count: 4_000)
      let n: Int32 = frame.withUnsafeBufferPointer { input -> Int32 in
        guard let inBase = input.baseAddress else { return -1 }
        return out.withUnsafeMutableBufferPointer { output -> Int32 in
          guard let outBase = output.baseAddress else { return -1 }
          return opus_encode(
            encoder, inBase, Int32(frameSamples),
            outBase, Int32(output.count))
        }
      }
      guard n > 0 else {
        throw OggOpusError.opus("opus_encode 失败：\(n)")
      }
      packets.append(Data(out.prefix(Int(n))))
      index += frameSamples
    }

    return try muxOgg(
      packets: packets,
      sampleRate: sampleRate,
      channels: channels,
      samplesPerPacket: frameSamples
    )
  }

  private static func muxOgg(
    packets: [Data],
    sampleRate: Int,
    channels: Int,
    samplesPerPacket: Int
  ) throws -> Data {
    var stream = ogg_stream_state()
    let serial = Int32.random(in: 1..<Int32.max)
    guard ogg_stream_init(&stream, serial) == 0 else {
      throw OggOpusError.ogg("ogg_stream_init 失败")
    }
    defer { ogg_stream_clear(&stream) }

    var output = Data()

    func drainPages(flush: Bool) {
      var page = ogg_page()
      while true {
        let got = flush
          ? ogg_stream_flush(&stream, &page)
          : ogg_stream_pageout(&stream, &page)
        if got == 0 { break }
        if let header = page.header, page.header_len > 0 {
          output.append(header, count: Int(page.header_len))
        }
        if let body = page.body, page.body_len > 0 {
          output.append(body, count: Int(page.body_len))
        }
      }
    }

    func packetIn(_ data: Data, granule: Int64, bos: Bool, eos: Bool, number: Int64) {
      data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        var packet = ogg_packet()
        packet.packet = UnsafeMutablePointer(mutating: base)
        packet.bytes = data.count
        packet.b_o_s = bos ? 1 : 0
        packet.e_o_s = eos ? 1 : 0
        packet.granulepos = granule
        packet.packetno = number
        ogg_stream_packetin(&stream, &packet)
      }
    }

    // OpusHead：v1、声道数、pre-skip（48k 采样）、原始输入采样率、增益 0、
    // 映射族 0（单声道不需要 channel mapping table）。
    var head = Data("OpusHead".utf8)
    head.append(1)
    head.append(UInt8(channels))
    head.append(UInt8(preSkip & 0xFF))
    head.append(UInt8((preSkip >> 8) & 0xFF))
    var rate = UInt32(sampleRate).littleEndian
    withUnsafeBytes(of: &rate) { head.append(contentsOf: $0) }
    head.append(contentsOf: [0, 0])  // output gain
    head.append(0)  // mapping family
    packetIn(head, granule: 0, bos: true, eos: false, number: 0)
    drainPages(flush: true)

    // OpusTags：vendor 长度 + vendor 字符串 + comment 条数。
    // **comment 条数不能省** —— 少了这 4 个字节，包尾就是截断的，
    // libopusfile 这类严格解析器会直接判定流损坏（服务端表现为 502）。
    let vendor = Data("pp_friend".utf8)
    var tags = Data("OpusTags".utf8)
    var vendorLen = UInt32(vendor.count).littleEndian
    withUnsafeBytes(of: &vendorLen) { tags.append(contentsOf: $0) }
    tags.append(vendor)
    var commentCount = UInt32(0).littleEndian
    withUnsafeBytes(of: &commentCount) { tags.append(contentsOf: $0) }
    packetIn(tags, granule: 0, bos: false, eos: false, number: 1)
    drainPages(flush: true)

    var granule: Int64 = Int64(preSkip)
    for (i, packet) in packets.enumerated() {
      // 每个 20ms 帧在 48k 下是 960 个采样。
      let samples48k = Int64(samplesPerPacket) * 48_000 / Int64(sampleRate)
      granule += samples48k
      packetIn(
        packet,
        granule: granule,
        bos: false,
        eos: i == packets.count - 1,
        number: Int64(i + 2)
      )
      // 第一包之后立刻刷一页，保证「第一个音频页不是最后一页」。
      // libsndfile（服务端转写常用的解码器）对只有单个数据页的文件会报
      // "First data page is also the last ... malformed"，短句直接被拒。
      if i == 0 || i == packets.count - 1 {
        drainPages(flush: true)
      } else {
        drainPages(flush: false)
      }
    }

    return output
  }
}
