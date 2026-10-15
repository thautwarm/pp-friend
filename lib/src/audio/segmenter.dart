import 'dart:typed_data';

/// 一句切好的话，附带音频本身。
///
/// 取代了旧的 `UtteranceCallback(Uint8List, double)` —— 那是个匿名二元组，
/// 采样率只能靠调用方自己记，正是上行采样率写错的温床。
class SpeechSegment {
  const SpeechSegment({
    required this.pcm16le,
    required this.sampleRate,
    required this.durationSeconds,
    this.forcedCut = false,
    this.probability = 0,
    this.truncated = false,
  });

  /// 单声道 PCM16LE。**采样率以 [sampleRate] 为准，不是采集率。**
  final Uint8List pcm16le;

  /// 这段音频自己的采样率。Silero 路径下恒为 16000 —— 重采样在 Rust 里做完了。
  final int sampleRate;

  final double durationSeconds;

  /// 说太久被强制切开，而不是等到停顿。不是真的说完了。
  final bool forcedCut;

  /// 切出这一句时的语音概率。调阈值时最有用的一个数。
  final double probability;

  /// 开头被环形缓冲挤掉了。正常恒为 false，出现就说明缓冲配小了。
  final bool truncated;
}

/// 一次 feed 之后能观察到的状态。调试面板全靠它。
class SegmenterStats {
  const SegmenterStats({
    this.speaking = false,
    this.probability = 0,
    this.bufferedMs = 0,
    this.droppedMs = 0,
    this.forcedCuts = 0,
    this.lastFeedMicros = 0,
  });

  /// 当前处于"正在说话"。
  final bool speaking;

  /// 最近一帧的语音概率，0~1。
  final double probability;

  /// 环形缓冲当前占用多少毫秒音频。
  final int bufferedMs;

  /// 累计被缓冲挤掉多少毫秒音频（正常恒为 0）。
  final int droppedMs;

  /// 累计强制切段次数。
  final int forcedCuts;

  /// 最近一次 feed 的耗时（微秒）。p99 超过 3ms 就得考虑挪出 main isolate。
  final int lastFeedMicros;

  static const SegmenterStats idle = SegmenterStats();
}

/// 本地断句的抽象。
///
/// 接口存在的唯一理由是让 `flutter test` 能注入假实现 —— 真实现在 host 上
/// 加载不了 `.so`，而 controller 的接线（上行采样率、双讲门、构造时序）
/// 恰恰是最需要测的部分，因为它没有任何别的测试覆盖。
abstract class Segmenter {
  /// 生产实现的名字，显示在调试面板的 chip 上。
  String get name;

  /// 喂一块 PCM16LE。长度任意，采样率必须是构造时声明的那个。
  ///
  /// **同步**：mic 帧在 main isolate 上送达，走异步返回的 Future 没人 await，
  /// 顺序就散了，得自己搭链。
  void feed(
    Uint8List pcm16le, {
    required void Function() onSpeechStart,
    required void Function(SpeechSegment segment) onUtterance,
  });

  SegmenterStats get stats;

  /// 清空模型状态和缓冲，重新开始计偏移。
  void reset();

  /// 释放底层句柄（Rust 侧 opaque Arc）。
  void dispose();
}
