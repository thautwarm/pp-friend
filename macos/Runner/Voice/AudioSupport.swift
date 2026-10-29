import Foundation

/// 把任意大小的 PCM16LE 块切成固定帧长（默认 20ms）。
///
/// 这层不碰 AVFoundation：以后 Windows/Linux 实现可以直接照这个语义写，
/// 也方便单测。
final class MicFramer {
  let frameBytes: Int
  private var pending = Data()

  /// 已经切出来的帧数（不含队列里没凑够的部分）。
  private(set) var totalFrames = 0

  init(frameBytes: Int) {
    precondition(frameBytes > 0)
    self.frameBytes = frameBytes
  }

  /// 喂一块数据，返回这次凑满的帧（可能 0 个或多个）。
  func append(_ chunk: Data) -> [Data] {
    pending.append(chunk)
    guard pending.count >= frameBytes else { return [] }

    var frames: [Data] = []
    var offset = pending.startIndex
    while pending.endIndex - offset >= frameBytes {
      let end = offset + frameBytes
      frames.append(Data(pending[offset..<end]))
      offset = end
    }
    if offset > pending.startIndex {
      pending.removeSubrange(pending.startIndex..<offset)
    }
    totalFrames += frames.count
    return frames
  }

  func reset() {
    pending.removeAll(keepingCapacity: true)
    totalFrames = 0
  }
}

/// 播放队列的 epoch / backlog 记账。
///
/// 语义必须和 Android `NativeVoiceEngine` 一致：
/// - `epoch` 小于当前值的块直接丢；
/// - flush 把没播出去的都算丢弃，播放头和计数归零；
/// - backlog 含已经排进设备、但还没播完的帧。
final class PlaybackTimeline {
  private(set) var epoch: Int64 = 0
  private(set) var scheduledFrames = 0
  private(set) var playedFrames = 0

  /// 每次 flush 自增。播放完成回调带着它回来，过期的回调不能算数。
  private(set) var generation: UInt64 = 0

  func accepts(epoch: Int64) -> Bool { epoch >= self.epoch }

  /// 排进设备，返回这次排队的 generation。
  func schedule(_ frames: Int) -> UInt64 {
    scheduledFrames += frames
    return generation
  }

  /// 某一块真正播完了。generation 对不上就忽略（flush 之前的尾巴）。
  func played(_ frames: Int, generation: UInt64) {
    guard generation == self.generation else { return }
    playedFrames += frames
    if playedFrames > scheduledFrames { playedFrames = scheduledFrames }
  }

  var backlogFrames: Int { max(0, scheduledFrames - playedFrames) }

  /// 抬高 epoch、清空计数，返回被丢弃的帧数。
  func flush(newEpoch: Int64) -> Int {
    let discarded = backlogFrames
    epoch = max(epoch, newEpoch)
    scheduledFrames = 0
    playedFrames = 0
    generation &+= 1
    return discarded
  }
}

/// RMS → dBFS。静默返回 -120（和 Android 的 SILENCE_DB 一致）。
func rmsDb(_ samples: UnsafePointer<Float>, count: Int) -> Double {
  guard count > 0 else { return -120 }
  var sum = 0.0
  for i in 0..<count {
    let v = Double(samples[i])
    sum += v * v
  }
  let rms = (sum / Double(count)).squareRoot()
  if rms <= 1e-7 { return -120 }
  return 20 * log10(rms)
}

func rmsDb(_ samples: [Float]) -> Double {
  samples.withUnsafeBufferPointer { buf in
    guard let base = buf.baseAddress else { return -120 }
    return rmsDb(base, count: buf.count)
  }
}

/// Float32（-1...1）→ Int16LE，带饱和。
func floatToInt16LE(_ samples: UnsafePointer<Float>, count: Int) -> Data {
  var out = Data(count: count * 2)
  out.withUnsafeMutableBytes { raw in
    guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
    for i in 0..<count {
      let v = max(-1.0, min(1.0, Double(samples[i])))
      base[i] = Int16(v * 32767.0)
    }
  }
  return out
}
