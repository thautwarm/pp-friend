import 'dart:typed_data';

import '../config/assistant_config.dart';
import '../rust/api/vad.dart';
import '../rust/frb_generated.dart';
import 'segmenter.dart';

/// 用 Rust 侧的 Silero VAD 切句。生产环境唯一的 [Segmenter] 实现。
///
/// 为什么不自己用 Dart 判：能量阈值分不清"句子中间的停顿"和"真的说完了"，
/// 只能靠调大静音窗口硬扛 —— 那正是"话没说完就被断句"的根因。Silero 是
/// 个真模型，判据本身强得多。
///
/// 模型（1.26MB ONNX）和 ONNX Runtime 都静态链在 `librust_lib_pp_friend.so`
/// 里，所以 Dart 侧只有这一层薄封装。
class SileroSegmenter implements Segmenter {
  SileroSegmenter._(this._handle);

  final SileroVadHandle _handle;

  final Stopwatch _watch = Stopwatch();
  SegmenterStats _stats = SegmenterStats.idle;
  bool _speaking = false;

  /// 构造并加载模型。
  ///
  /// 这一步是**几十到几百毫秒**（读 1.26MB 模型 + ONNX 图优化），
  /// 调用方必须在开始收麦克风之前 await 完，不能让第一帧撞上它。
  ///
  /// 失败会抛异常（`.so` 没打进包、ABI 不匹配、模型损坏）。能量 VAD 已经
  /// 删了，这里**没有静默退路** —— 调用方必须把异常变成用户看得见的提示。
  static Future<SileroSegmenter> open({
    required int inputSampleRate,
    required AssistantConfig config,
  }) async {
    await _ensureRust();
    final cfg = SegmenterConfig(
      inputSampleRate: inputSampleRate,
      threshold: config.vadThreshold,
      minSilenceMs: config.vadMinSilenceMs,
      speechPadMs: config.vadSpeechPadMs,
      minSpeechMs: config.vadMinSpeechMs,
      maxSpeechMs: config.vadMaxSpeechS * 1000,
      ringCapacityMs: config.vadRingCapacityMs,
    );
    return SileroSegmenter._(SileroVadHandle(cfg: cfg));
  }

  /// `RustLib.init()` 会**抛异常如果调第二次**，所以必须先查再调。
  static Future<void> _ensureRust() async {
    if (RustLib.instance.initialized) return;
    await RustLib.init();
  }

  @override
  String get name => 'Silero (Rust)';

  @override
  SegmenterStats get stats => _stats;

  @override
  void feed(
    Uint8List pcm16le, {
    required void Function() onSpeechStart,
    required void Function(SpeechSegment segment) onUtterance,
  }) {
    if (_handle.isDisposed) return;

    _watch
      ..reset()
      ..start();
    final result = _handle.feed(pcm16Le: pcm16le);
    _watch.stop();

    if (result.speaking && !_speaking) onSpeechStart();

    for (final s in result.segments) {
      onUtterance(
        SpeechSegment(
          pcm16le: s.pcm16Le,
          // 用 segment 自己声明的采样率，**不是**采集率。
          sampleRate: s.sampleRate,
          durationSeconds: s.durationMs / 1000,
          forcedCut: s.forcedCut,
          probability: result.prob,
          truncated: s.truncated,
        ),
      );
    }

    _speaking = result.speaking;
    _stats = SegmenterStats(
      speaking: result.speaking,
      probability: result.prob,
      bufferedMs: result.bufferedMs,
      droppedMs: result.droppedMs,
      forcedCuts: _handle.forcedCuts(),
      lastFeedMicros: _watch.elapsedMicroseconds,
    );
  }

  @override
  void reset() {
    if (_handle.isDisposed) return;
    _handle.reset();
    _speaking = false;
    _stats = SegmenterStats.idle;
  }

  @override
  void dispose() {
    if (_handle.isDisposed) return;
    _handle.dispose();
    _stats = SegmenterStats.idle;
  }
}
