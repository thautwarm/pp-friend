import 'dart:async';
import 'dart:typed_data';

import 'package:pp_friend/src/audio/segmenter.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/voice/voice_engine.dart';

/// 假引擎用的采集率。
///
/// **故意不是 16000** —— 只有它和 Silero 的输出（[fakeSileroRate]）不一样，
/// "上行必须用 segment 自己的采样率"那条断言才有区分度：写成采集率也会过。
const int fakeCaptureRate = 48000;
const int fakeSileroRate = 16000;

/// 记录 controller 的每一次外向调用。断言只看这里。
///
/// 生产实现要加载 .so，host 上跑不起来 —— 测试全靠这两个假货。
class FakeVoiceEngine implements VoiceEngine {
  FakeVoiceEngine([this.order]);

  /// 需要断言"调用的先后顺序"时传进来（例如 segmenter 必须早于 micPcm 订阅）。
  final List<String>? order;

  final StreamController<Uint8List> micCtrl =
      StreamController<Uint8List>.broadcast();
  final StreamController<AudioLevels> levelCtrl =
      StreamController<AudioLevels>.broadcast();
  final StreamController<EngineEvent> eventCtrl =
      StreamController<EngineEvent>.broadcast();

  int micListenCount = 0;
  int playbackPushes = 0;

  /// 被清空过几次（打断/手动停都算）。
  int flushCount = 0;

  /// 上行编码时用到的采样率，按调用顺序。
  final List<int> encodedSampleRates = <int>[];

  /// 播放头（毫秒）。测试直接改它来模拟"已经播到第几秒"。
  int headMs = 0;

  /// 缓冲里还剩多少帧没响出来。
  ///
  /// 假引擎用它模拟真机上的那个状态：推送循环早退了，声音还在响。
  int backlogFrames = 0;

  /// `decodeAudio` 返回的 PCM 和采样率。要给非空的才能让"播放"这条路跑起来。
  Uint8List decodedPcm = Uint8List(0);
  int decodedRate = 48000;

  /// 调过几次 [decodeAudio]。
  int decodeCalls = 0;

  /// 从这里开始（1 起算）的第二次解码会挂住，直到测试放行。
  ///
  /// 用来制造"这一块已经入站、但还没解码/推进原生队列"的中间态。
  int decodeGateAfter = 0;
  Completer<void>? decodeGate;

  /// 本机有没有 Opus 编码器。默认**没有** —— 那是最省事的一条路：
  /// 上行到此为止，不会真的去打网络。
  bool opusUpstream = false;

  static const AudioFormat format = AudioFormat(
    sampleRate: fakeCaptureRate,
    channels: 1,
    framesPerChunk: 960,
  );

  @override
  Stream<Uint8List> get micPcm {
    micListenCount++;
    order?.add('micSub');
    return micCtrl.stream;
  }

  @override
  Stream<AudioLevels> get levels => levelCtrl.stream;

  @override
  Stream<EngineEvent> get events => eventCtrl.stream;

  @override
  Future<AudioFormat> startAudio({int preferredSampleRate = 16000}) async =>
      format;

  @override
  Future<void> stopAudio() async {}

  @override
  Future<bool> audioRunning() async => false;

  @override
  Future<void> startService() async {}

  @override
  Future<void> stopService() async {}

  @override
  Future<bool> serviceRunning() async => false;

  @override
  Future<int> droppedMicFrames() async => 0;

  @override
  Future<int> playbackBacklogFrames() async => backlogFrames;

  @override
  Future<int> playbackHeadMs() async => headMs;

  /// 设了它，[pushPlayback] 会一直挂着直到测试放行。
  ///
  /// 假引擎里推送是瞬时的，没有"正在播"这个窗口 —— 要测"播放中被打断、
  /// 紧接着又来一条"就必须把这个状态按在手里。
  Completer<void>? pushGate;

  /// 前 [pushGateAfter] 次推送正常返回，从下一次开始挂住。
  ///
  /// 用来制造"前面几块已经推进队列、当前这块卡在推送里"的中间态。
  int pushGateAfter = 0;

  @override
  Future<void> pushPlayback(Uint8List pcm16le, {required int epoch}) async {
    playbackPushes++;
    final gate = pushGate;
    if (gate != null && playbackPushes > pushGateAfter) await gate.future;
  }

  @override
  Future<int> flushPlayback({required int newEpoch}) async {
    flushCount++;
    // 真机 flush 会把 AudioTrack 内部缓冲一起丢掉，播放头归零。
    final discarded = backlogFrames;
    backlogFrames = 0;
    headMs = 0;
    return discarded;
  }

  @override
  Future<DebugAudioProfile> applyDebugProfile(
    DebugAudioProfile profile,
  ) async => profile;

  @override
  Future<DebugAudioProfile> currentDebugProfile() async =>
      const DebugAudioProfile();

  /// 原生侧那个布尔值在测试里的对应物。默认 true = 拦截。
  bool volumeKeyClearsQueue = true;

  /// 记录每一次推送。断言"改了配置会不会真的推下去"要用它 ——
  /// 只看当前值的话，会漏掉"推了但值没变"和"根本没推"这两种。
  final List<bool> volumeKeyPushes = <bool>[];

  @override
  Future<void> setVolumeKeyClearsQueue(bool enabled) async {
    volumeKeyClearsQueue = enabled;
    volumeKeyPushes.add(enabled);
  }

  @override
  Future<DecodedAudio> decodeAudio(Uint8List bytes) async {
    decodeCalls++;
    final gate = decodeGate;
    if (gate != null && decodeCalls > decodeGateAfter) await gate.future;
    return DecodedAudio(
      pcm16le: decodedPcm,
      sampleRate: decodedRate,
      channels: 1,
    );
  }

  /// 一条回复的连续音频流里，是否已经吐过 PCM。
  ///
  /// 真的流式解码器可能分好几次才吐完；测试只关心"这条有没有声音"，
  /// 所以第一条 feed 就吐完整段 [decodedPcm]，后面再 feed 返回 null。
  bool _fedCurrentStream = false;

  @override
  Future<DecodedAudio?> feedOggStream(Uint8List bytes) async {
    if (_fedCurrentStream || decodedPcm.isEmpty) {
      decodeCalls++;
      return null;
    }
    decodeCalls++;
    final gate = decodeGate;
    if (gate != null && decodeCalls > decodeGateAfter) await gate.future;
    _fedCurrentStream = true;
    return DecodedAudio(
      pcm16le: decodedPcm,
      sampleRate: decodedRate,
      channels: 1,
    );
  }

  @override
  Future<DecodedAudio?> finishOggStream() async {
    _fedCurrentStream = false;
    return null;
  }

  @override
  Future<void> resetOggStream() async {
    _fedCurrentStream = false;
  }

  @override
  Future<bool> opusEncoderAvailable() async => opusUpstream;

  @override
  Future<Uint8List?> encodeOpus(
    Uint8List pcm16le, {
    required int sampleRate,
    int channels = 1,
  }) async {
    encodedSampleRates.add(sampleRate);
    if (!opusUpstream) return null;
    // 内容无所谓，只有长度在后面的路径里被用到（_kb）
    return Uint8List.fromList(const <int>[1, 2, 3, 4]);
  }

  @override
  void dispose() {}

  void close() {
    micCtrl.close();
    levelCtrl.close();
    eventCtrl.close();
  }
}

/// 记录每一帧喂进来的内容，并允许测试手动"切出一句 / 开口"。
class FakeSegmenter implements Segmenter {
  final List<Uint8List> frames = <Uint8List>[];
  final List<int> sampleRates = <int>[];
  final List<AssistantConfig> configs = <AssistantConfig>[];

  bool disposed = false;
  int resetCount = 0;

  /// 下一次读 [stats] 时返回什么。测试靠它模拟"正在说（概率多少）"。
  ///
  /// 默认是 [SegmenterStats.idle]（没在说、概率 0），也就是安静时的样子。
  SegmenterStats statsValue = SegmenterStats.idle;

  Function()? _onSpeechStart;
  Function(SpeechSegment)? _onUtterance;
  void Function(FilteredSegment)? _onFiltered;

  /// 挂门控时喂进来的声纹。测试可以用来断言"导入之后确实挂上了"。
  Uint8List? gateVoiceprint;
  double? gateThreshold;
  double? gateMinTargetRatio;
  double? gateMinCosine;
  int gateAttachCount = 0;
  int gateDetachCount = 0;
  bool gateAttachSucceeds = true;
  String? gateError;

  @override
  Future<bool> attachSpeakerGate(
    Uint8List spkemb, {
    required double threshold,
    required double minTargetRatio,
    required double minCosine,
  }) async {
    gateAttachCount++;
    gateVoiceprint = spkemb;
    gateThreshold = threshold;
    gateMinTargetRatio = minTargetRatio;
    gateMinCosine = minCosine;
    gateError = gateAttachSucceeds ? null : '假的门控失败';
    return gateAttachSucceeds;
  }

  @override
  void detachSpeakerGate() {
    gateDetachCount++;
    gateError = null;
  }

  @override
  String? get speakerGateError => gateError;

  @override
  String get name => 'fake';

  @override
  SegmenterStats get stats => statsValue;

  @override
  void feed(
    Uint8List pcm16le, {
    required void Function() onSpeechStart,
    required void Function(SpeechSegment segment) onUtterance,
    void Function(FilteredSegment segment)? onFiltered,
  }) {
    // 必须复制：controller 对静音那一路是复用同一块零缓冲的。
    frames.add(Uint8List.fromList(pcm16le));
    _onSpeechStart = onSpeechStart;
    _onUtterance = onUtterance;
    _onFiltered = onFiltered;
  }

  /// 手动"门控丢了一段"。
  void emitFiltered(FilteredSegment segment) {
    final cb = _onFiltered;
    if (cb == null) throw StateError('还没喂过帧');
    cb(segment);
  }

  @override
  void reset() => resetCount++;

  @override
  void dispose() => disposed = true;

  /// 手动"切出一句"。
  void emit(SpeechSegment segment) {
    final cb = _onUtterance;
    if (cb == null) {
      throw StateError('还没喂过帧 —— controller 的回调是 feed 时递进来的');
    }
    cb(segment);
  }

  /// 手动"用户开口了"。
  void speechStart() {
    final cb = _onSpeechStart;
    if (cb == null) {
      throw StateError('还没喂过帧 —— controller 的回调是 feed 时递进来的');
    }
    cb();
  }
}
