import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

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

  /// 挂门控失败的原因。界面拿它解释"为什么开了没效果"。
  @override
  String? get speakerGateError => _speakerGateError;
  String? _speakerGateError;

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
    void Function(FilteredSegment segment)? onFiltered,
  }) {
    if (_handle.isDisposed) return;

    _watch
      ..reset()
      ..start();
    final result = _handle.feed(pcm16Le: pcm16le);
    _watch.stop();

    if (result.speaking && !_speaking) onSpeechStart();

    // 先落状态再回调：`onUtterance` 里要读这次 feed 的真实耗时（声纹推理
    // 就发生在里面），放到回调后面读到的还是上一次的。这个数只在调试日志
    // 和面板上用，不影响判定。
    _speaking = result.speaking;
    _stats = SegmenterStats(
      speaking: result.speaking,
      probability: result.prob,
      bufferedMs: result.bufferedMs,
      droppedMs: result.droppedMs,
      forcedCuts: _handle.forcedCuts(),
      lastFeedMicros: _watch.elapsedMicroseconds,
      pvadEnabled: result.pvadEnabled,
      pvadProb: result.pvadProb,
      pvadFiltered: _handle.pvadFiltered(),
      speakerVerifyEnabled: result.speakerVerifyEnabled,
      speakerCos: result.speakerCos,
    );

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
          pvadScore: s.pvadScore,
          pvadTargetRatio: s.pvadTargetRatio,
          speakerCos: s.speakerCos,
        ),
      );
    }

    if (onFiltered != null) {
      for (final s in result.filtered) {
        onFiltered(FilteredSegment(
          startMs: s.startMs,
          endMs: s.endMs,
          durationMs: s.durationMs,
          pvadScore: s.pvadScore,
          pvadTargetRatio: s.pvadTargetRatio,
          speakerCos: s.speakerCos,
        ));
      }
    }

  }

  @override
  Future<bool> attachSpeakerGate(
    Uint8List spkemb, {
    required double threshold,
    required double minTargetRatio,
    required double minCosine,
  }) async {
    if (_handle.isDisposed) return false;
    try {
      // 实测 pVAD 的 sigmoid 主要反映"像不像语音"，对"是谁"很弱：
      // 目标人和家人能一起到 0.9。它的逐帧推理还要一直吃 CPU，所以
      // 默认判据完全交给 ECAPA cosine，不再挂 pVAD。
      //
      // Rust 侧的 setPvad 保留着，想切回去随时可以调；参数 threshold /
      // minTargetRatio 也还留在签名和配置里，给短段兜底用。
      //
      // 这个模型 81 MiB，**故意不缓存**在 Dart 侧：Rust 的 session 已经
      // 持有权重了，再把字节留一份在 Dart 堆里只是白占 81 MiB。
      // 每次挂门控重读一次资产，换来的是一次会话只多几百毫秒启动时间。
      final data = await rootBundle.load('assets/models/ecapa.onnx');
      final ecapa =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      _handle.setSpeakerVerifier(
        model: ecapa,
        spkemb: spkemb,
        cfg: SpeakerVerifyConfig(
          minCosine: minCosine,
          // 声纹在 300ms 上已经能分人（干净语音下同一人 cos 0.6 左右，
          // 不同人 0.1~0.2），而 Silero 本来就把 <300ms 的段丢了。
          minVerifyMs: 300,
        ),
      );
      _speakerGateError = null;
      return _handle.pvadEnabled();
    } catch (e) {
      _speakerGateError = '$e';
      return false;
    }
  }

  @override
  void detachSpeakerGate() {
    if (_handle.isDisposed) return;
    _handle.clearPvad();
    _speakerGateError = null;
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
