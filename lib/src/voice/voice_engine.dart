import 'dart:typed_data';

import 'method_channel_voice_engine.dart';

/// 原生侧实际选定的音频格式。
///
/// 这个值由 `startAudio()` 返回，**Dart 必须按它来理解 micPcm、也必须按它来
/// 生成 pushPlayback 的数据**。本期原生不做重采样，所以如果设备不支持 16k，
/// 这里会是 48000 之类，STT/TTS 侧要跟着走。
class AudioFormat {
  const AudioFormat({
    required this.sampleRate,
    required this.channels,
    required this.framesPerChunk,
  });

  final int sampleRate;
  final int channels;

  /// 每个 micPcm 事件大约包含多少帧（不是精确保证，最后一个事件可能更短）。
  final int framesPerChunk;

  int get bytesPerFrame => channels * 2;

  Duration get chunkDuration =>
      Duration(microseconds: framesPerChunk * 1000000 ~/ sampleRate);

  factory AudioFormat.fromMap(Map<dynamic, dynamic> map) => AudioFormat(
    sampleRate: (map['sampleRate'] as num).toInt(),
    channels: (map['channels'] as num).toInt(),
    framesPerChunk: (map['framesPerChunk'] as num).toInt(),
  );

  @override
  String toString() => '${sampleRate}Hz/${channels}ch/${framesPerChunk}frames';
}

/// 双讲检测所需的两个电平。单位 dBFS，静默为 -120。
class AudioLevels {
  const AudioLevels({required this.micDb, required this.playbackDb});

  /// AEC 之后的麦克风电平。
  final double micDb;

  /// **当前正在送出的播放电平** —— 双讲检测的参考信号。
  ///
  /// 没有它就区分不了「用户在说话」和「AI 自己的残留回声」，
  /// 只能靠绝对能量阈值硬判，那正是要避免的误触发。
  final double playbackDb;

  @override
  String toString() =>
      'mic=${micDb.toStringAsFixed(1)}dB playback=${playbackDb.toStringAsFixed(1)}dB';
}

/// 原生解码出来的音频。采样率和声道数是**它自己的**，
/// 调用方负责转成播放引擎要的格式。
class DecodedAudio {
  const DecodedAudio({
    required this.pcm16le,
    required this.sampleRate,
    required this.channels,
  });

  final Uint8List pcm16le;
  final int sampleRate;
  final int channels;
}

// ---------------------------------------------------------------------------
// 调试用音频配置：对应文档里的实测矩阵，一次只动一个变量
// ---------------------------------------------------------------------------

enum CaptureSource {
  voiceCommunication,
  mic,
  voiceRecognition,
  camcorder,
  unprocessed,
}

enum PlaybackUsage { voiceCommunication, media }

enum AudioPerformanceMode { none, lowLatency }

enum AudioManagerMode { inCommunication, normal }

class DebugAudioProfile {
  const DebugAudioProfile({
    this.captureSource = CaptureSource.voiceCommunication,
    this.playbackUsage = PlaybackUsage.voiceCommunication,
    this.performanceMode = AudioPerformanceMode.none,
    this.manualAec = false,
    this.speakerphone = true,
    this.audioManagerMode = AudioManagerMode.inCommunication,
  });

  final CaptureSource captureSource;

  /// 用 media 时 AEC 拿不到参考信号 —— 实测矩阵里最该先对比的一项。
  final PlaybackUsage playbackUsage;

  /// lowLatency 延迟低，但官方文档写明 effects may not work，AEC 就是 effect。
  final AudioPerformanceMode performanceMode;

  /// 手动叠加 AcousticEchoCanceler，与 voiceCommunication 是两条不同路径。
  final bool manualAec;

  final bool speakerphone;

  final AudioManagerMode audioManagerMode;

  Map<String, dynamic> toMap() => {
    'captureSource': captureSource.name,
    'playbackUsage': playbackUsage.name,
    'performanceMode': performanceMode.name,
    'manualAec': manualAec,
    'speakerphone': speakerphone,
    'audioManagerMode': audioManagerMode.name,
  };

  DebugAudioProfile copyWith({
    CaptureSource? captureSource,
    PlaybackUsage? playbackUsage,
    AudioPerformanceMode? performanceMode,
    bool? manualAec,
    bool? speakerphone,
    AudioManagerMode? audioManagerMode,
  }) => DebugAudioProfile(
    captureSource: captureSource ?? this.captureSource,
    playbackUsage: playbackUsage ?? this.playbackUsage,
    performanceMode: performanceMode ?? this.performanceMode,
    manualAec: manualAec ?? this.manualAec,
    speakerphone: speakerphone ?? this.speakerphone,
    audioManagerMode: audioManagerMode ?? this.audioManagerMode,
  );

  static DebugAudioProfile fromMap(
    Map<dynamic, dynamic> map,
  ) => DebugAudioProfile(
    captureSource: CaptureSource.values.byName(map['captureSource'] as String),
    playbackUsage: PlaybackUsage.values.byName(map['playbackUsage'] as String),
    performanceMode: AudioPerformanceMode.values.byName(
      map['performanceMode'] as String,
    ),
    manualAec: map['manualAec'] as bool,
    speakerphone: map['speakerphone'] as bool,
    audioManagerMode: AudioManagerMode.values.byName(
      map['audioManagerMode'] as String,
    ),
  );
}

// ---------------------------------------------------------------------------
// 引擎事件
// ---------------------------------------------------------------------------

sealed class EngineEvent {
  const EngineEvent();
}

/// 音频焦点被抢。三种语义对应三种处理，所以不能用一个 bool 表示。
class InterruptionBegan extends EngineEvent {
  const InterruptionBegan({required this.transient, required this.canDuck});

  /// false = AUDIOFOCUS_LOSS，永久失去，应当结束会话。
  final bool transient;

  /// true = 可以降音量继续播。
  final bool canDuck;
}

class InterruptionEnded extends EngineEvent {
  const InterruptionEnded({required this.shouldResume});
  final bool shouldResume;
}

/// 麦克风静默失效 —— 不报错，只是没声音。文档里点名的那个坑，必须能观测到。
class MicSilentlyDead extends EngineEvent {
  const MicSilentlyDead(this.reason);
  final String reason;
}

class EngineFailure extends EngineEvent {
  const EngineFailure(this.reason);
  final String reason;
}

/// 手动 AEC 在本机不可用（要么设备不支持，要么被 voiceCommunication 路径占用）。
class ManualAecUnavailable extends EngineEvent {
  const ManualAecUnavailable();
}

/// 通知栏「结束」按钮被按下。收尾交给 Dart，避免原生单方面掐断导致状态不一致。
class EndRequested extends EngineEvent {
  const EndRequested();
}

/// 请求清空正在播放的 AI 语音（通知栏「停止说话」按钮，或前台的音量减键）。
///
/// 只清音频，会话继续 —— 文本该进消息流照样进。
class ClearPlaybackRequested extends EngineEvent {
  const ClearPlaybackRequested();
}

// ---------------------------------------------------------------------------
// 契约
// ---------------------------------------------------------------------------

abstract class VoiceEngine {
  static VoiceEngine? _instance;

  /// 进程内单例。原生侧也是单例，Dart 侧跟着保持同一个对象，
  /// 否则 EventChannel 的订阅会被反复重建。
  static VoiceEngine get instance => _instance ??= MethodChannelVoiceEngine();

  /// 仅用于测试替换实现。
  static set instance(VoiceEngine engine) => _instance = engine;

  // ---- 前台服务：与音频解耦，各自幂等 ----
  //
  // 拆开的原因：FGS 必须在 App 处于前台时启动，且 startForeground() 要在
  // startForegroundService() 后 5 秒内调用。和音频绑成一个调用的话，失败时
  // Dart 分不清是服务没起来还是音频没起来。

  Future<void> startService();
  Future<void> stopService();
  Future<bool> serviceRunning();

  // ---- 音频链路 ----

  Future<AudioFormat> startAudio({int preferredSampleRate = 16000});
  Future<void> stopAudio();
  Future<bool> audioRunning();

  /// 采集 PCM。16-bit LE。广播流；**没有订阅者时原生直接丢帧，不做缓冲**。
  ///
  /// 背压策略是 drop-oldest，丢弃量见 [droppedMicFrames]。
  Stream<Uint8List> get micPcm;

  /// 电平遥测，约 30Hz，只保留最新值。
  Stream<AudioLevels> get levels;

  /// 离散事件。
  Stream<EngineEvent> get events;

  /// 因背压被丢弃的采集帧数。用来确认延迟没有在暗中累积。
  Future<int> droppedMicFrames();

  /// 播放缓冲区里还没播出去的帧数，Dart 据此对 TTS 做背压。
  Future<int> playbackBacklogFrames();

  /// 本次播放**已经播出去**多少毫秒。
  ///
  /// 打断时上报给 brain 的就是这个数（"你这段话我听到第几秒"）。
  /// 必须问原生要 AudioTrack 的播放头：我们自己知道推下去了多少，
  /// 但推进缓冲区不等于播出来了，中间的差值就是用户还没听到的部分。
  ///
  /// 清空播放（打断）会把播放头归零，所以它是"从上次清空算起"的位置 ——
  /// Dart 侧要拿播放开始时的值做基线才等于"这条回复里已播多少"。
  /// 没在播放时返回 0。
  Future<int> playbackHeadMs();

  /// 推入一段播放数据。
  ///
  /// [epoch] 是打断的序号：原生会丢弃所有 epoch 小于当前值的缓冲，
  /// 所以即便 TTS 流的下一块迟到了，也不会在被打断之后再冒出来。
  Future<void> pushPlayback(Uint8List pcm16le, {required int epoch});

  /// 打断。抬高 epoch、清空缓冲，返回被丢弃的帧数（已播出去的不算），
  /// Dart 可以据此截断对话上下文。
  Future<int> flushPlayback({required int newEpoch});

  /// 只影响原生侧音频配置，不承载业务逻辑。
  Future<DebugAudioProfile> applyDebugProfile(DebugAudioProfile profile);

  Future<DebugAudioProfile> currentDebugProfile();

  /// 音量减键要不要当成"让它闭嘴"。
  ///
  /// 这个开关活在 Dart 侧（配置里），而按键是在 Activity 的 onKeyDown 里
  /// 收到的 —— 原生拿不到配置，只能这样推下去。默认 true 由原生侧兜底，
  /// 所以启动时不调它也不会漏。
  Future<void> setVolumeKeyClearsQueue(bool enabled);

  /// 把压缩音频（OGG/Opus、WAV、MP3…）解成 PCM16。
  ///
  /// 必须在原生做：Dart 侧没有可用的 Opus 解码器。
  Future<DecodedAudio> decodeAudio(Uint8List bytes);

  /// 喂一块**连续 Ogg Opus 流**，返回这次解出来的 PCM。
  ///
  /// 解码器是带状态的：第一次调用从流里读 OpusHead 建解码器，之后每次
  /// 攒够完整的 Ogg page / Opus packet 就吐 PCM。没有输出时返回 null。
  /// 采样率以解码器**实际输出**为准。
  Future<DecodedAudio?> feedOggStream(Uint8List bytes);

  /// 流结束：送 EOS，把解码器里剩下的 PCM 收干净并释放。
  Future<DecodedAudio?> finishOggStream();

  /// 打断 / 切档案：丢掉当前解码状态，不等剩余音频。
  Future<void> resetOggStream();

  /// 本机有没有 Opus 编码器。
  ///
  /// **运行时探测，不要按 API 级别判** —— OEM 差异真实存在，
  /// 有些 API 29+ 的机器也可能缺这个编码器。
  Future<bool> opusEncoderAvailable();

  /// PCM16 → Ogg Opus。不可用或失败时返回 null。
  ///
  /// 上行用 Opus 的理由是体积（256kbps → ~16kbps），局域网上差别不大，
  /// 但走移动数据时不该推裸 PCM。**没有 WAV 回落** ——
  /// 服务端规范只收 Ogg Opus，发别的格式必然失败。
  Future<Uint8List?> encodeOpus(
    Uint8List pcm16le, {
    required int sampleRate,
    int channels = 1,
  });

  void dispose();
}
