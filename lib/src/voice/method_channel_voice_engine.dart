import 'dart:async';

import 'package:flutter/services.dart';

import 'network_check.dart';
import 'voice_engine.dart';

/// [VoiceEngine] 的 MethodChannel 实现。
///
/// 四条通道对应原生侧的四条，频率、载荷和背压策略各不相同：
/// 采集是高频二进制，电平是中频遥测，事件是低频离散。
class MethodChannelVoiceEngine implements VoiceEngine {
  static const MethodChannel _method = MethodChannel('pp_friend/voice_engine');
  static const EventChannel _micChannel = EventChannel(
    'pp_friend/voice_engine/mic',
  );
  static const EventChannel _levelChannel = EventChannel(
    'pp_friend/voice_engine/levels',
  );
  static const EventChannel _eventChannel = EventChannel(
    'pp_friend/voice_engine/events',
  );

  Stream<Uint8List>? _micStream;
  Stream<AudioLevels>? _levelStream;
  Stream<EngineEvent>? _eventStream;

  @override
  Stream<Uint8List> get micPcm =>
      _micStream ??= _micChannel.receiveBroadcastStream().map((event) {
        if (event is Uint8List) return event;
        return Uint8List.fromList((event as List).cast<int>());
      });

  @override
  Stream<AudioLevels> get levels =>
      _levelStream ??= _levelChannel.receiveBroadcastStream().map((event) {
        final list = (event as List).cast<num>();
        return AudioLevels(
          micDb: list[0].toDouble(),
          playbackDb: list[1].toDouble(),
        );
      });

  @override
  Stream<EngineEvent> get events => _eventStream ??= _eventChannel
      .receiveBroadcastStream()
      .map((event) => _parseEvent((event as Map).cast<String, dynamic>()))
      .where((event) => event != null)
      .cast<EngineEvent>();

  EngineEvent? _parseEvent(Map<String, dynamic> map) {
    switch (map['type'] as String?) {
      case 'interruptionBegan':
        return InterruptionBegan(
          transient: map['transient'] as bool? ?? true,
          canDuck: map['canDuck'] as bool? ?? false,
        );
      case 'interruptionEnded':
        return InterruptionEnded(
          shouldResume: map['shouldResume'] as bool? ?? true,
        );
      case 'micSilentlyDead':
        return MicSilentlyDead(map['reason'] as String? ?? '未知原因');
      case 'engineFailure':
        return EngineFailure(map['reason'] as String? ?? '未知原因');
      case 'manualAecUnavailable':
        return const ManualAecUnavailable();
      case 'endRequested':
        return const EndRequested();
      case 'clearPlaybackRequested':
        return const ClearPlaybackRequested();
      default:
        return null;
    }
  }

  // ------------------------------------------------------------ 前台服务

  @override
  Future<void> startService() => _method.invokeMethod<void>('startService');

  @override
  Future<void> stopService() => _method.invokeMethod<void>('stopService');

  @override
  Future<bool> serviceRunning() async =>
      await _method.invokeMethod<bool>('serviceRunning') ?? false;

  @override
  Future<void> prepareNetworkAccess(String baseUrl) async {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || uri.host.isEmpty) return;
    if (!looksLikeLocalNetworkHost(uri.host)) return;
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    try {
      await _method.invokeMethod<String>('probeLocalNetwork', {
        'host': uri.host,
        'port': port,
        // 5 秒足够用户看一眼系统弹窗；不弹的时候也别把启动卡太久。
        'timeoutMs': 5000,
      });
    } on MissingPluginException {
      // 其他平台没实现这个方法：本地网络权限只在 macOS 15+ 上存在。
    } on PlatformException {
      // 探测失败不代表会话一定失败（比如 brain 只是暂时没开），
      // 真正的请求失败会走 brainError，不在这里拦。
    }
  }


  // ------------------------------------------------------------ 音频链路

  @override
  Future<AudioFormat> startAudio({int preferredSampleRate = 16000}) async {
    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'startAudio',
        {'preferredSampleRate': preferredSampleRate},
      );
      if (result == null) {
        throw StateError('原生未返回音频格式');
      }
      return AudioFormat.fromMap(result);
    } on PlatformException catch (e) {
      throw StateError('开启音频失败：${e.message ?? e.code}');
    }
  }

  @override
  Future<void> stopAudio() => _method.invokeMethod<void>('stopAudio');

  @override
  Future<bool> audioRunning() async =>
      await _method.invokeMethod<bool>('isAudioRunning') ?? false;

  @override
  Future<int> droppedMicFrames() async =>
      await _method.invokeMethod<int>('droppedMicFrames') ?? 0;

  @override
  Future<int> playbackBacklogFrames() async =>
      await _method.invokeMethod<int>('playbackBacklogFrames') ?? 0;

  @override
  Future<int> playbackHeadMs() async =>
      await _method.invokeMethod<int>('playbackHeadMs') ?? 0;

  @override
  Future<void> pushPlayback(Uint8List pcm16le, {required int epoch}) => _method
      .invokeMethod<void>('pushPlayback', {'pcm': pcm16le, 'epoch': epoch});

  @override
  Future<int> flushPlayback({required int newEpoch}) async =>
      await _method.invokeMethod<int>('flushPlayback', {
        'newEpoch': newEpoch,
      }) ??
      0;

  // ------------------------------------------------------------ 调试配置

  @override
  Future<DebugAudioProfile> applyDebugProfile(DebugAudioProfile profile) async {
    final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
      'applyDebugProfile',
      profile.toMap(),
    );
    return result == null ? profile : DebugAudioProfile.fromMap(result);
  }

  @override
  Future<void> setVolumeKeyClearsQueue(bool enabled) async {
    await _method.invokeMethod<void>('setVolumeKeyClearsQueue', {
      'enabled': enabled,
    });
  }

  @override
  Future<DebugAudioProfile> currentDebugProfile() async {
    // 原生只在 apply 时回传，这里用默认值兜底即可。
    return const DebugAudioProfile();
  }

  @override
  Future<DecodedAudio> decodeAudio(Uint8List bytes) async {
    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'decodeAudio',
        {'bytes': bytes},
      );
      if (result == null) throw StateError('原生未返回解码结果');

      final pcm = result['pcm'];
      return DecodedAudio(
        pcm16le: pcm is Uint8List
            ? pcm
            : Uint8List.fromList((pcm as List).cast<int>()),
        sampleRate: (result['sampleRate'] as num).toInt(),
        channels: (result['channels'] as num).toInt(),
      );
    } on PlatformException catch (e) {
      throw StateError('解码音频失败：${e.message ?? e.code}');
    }
  }

  @override
  Future<DecodedAudio?> feedOggStream(Uint8List bytes) async {
    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'feedOggStream',
        {'bytes': bytes},
      );
      return _decoded(result);
    } on PlatformException catch (e) {
      throw StateError('流式解码音频失败：${e.message ?? e.code}');
    }
  }

  @override
  Future<DecodedAudio?> finishOggStream() async {
    try {
      final result = await _method.invokeMethod<Map<dynamic, dynamic>>(
        'finishOggStream',
      );
      return _decoded(result);
    } on PlatformException catch (e) {
      throw StateError('收尾解码音频失败：${e.message ?? e.code}');
    }
  }

  @override
  Future<void> resetOggStream() async {
    await _method.invokeMethod<void>('resetOggStream');
  }

  static DecodedAudio? _decoded(Map<dynamic, dynamic>? result) {
    if (result == null) return null;
    final pcm = result['pcm'];
    final bytes = pcm is Uint8List
        ? pcm
        : pcm is List
        ? Uint8List.fromList(pcm.cast<int>())
        : Uint8List(0);
    if (bytes.isEmpty) return null;
    return DecodedAudio(
      pcm16le: bytes,
      sampleRate: (result['sampleRate'] as num).toInt(),
      channels: (result['channels'] as num).toInt(),
    );
  }

  @override
  Future<bool> opusEncoderAvailable() async =>
      await _method.invokeMethod<bool>('opusEncoderAvailable') ?? false;

  @override
  Future<Uint8List?> encodeOpus(
    Uint8List pcm16le, {
    required int sampleRate,
    int channels = 1,
  }) async {
    try {
      final result = await _method.invokeMethod<Uint8List>('encodeOpus', {
        'pcm': pcm16le,
        'sampleRate': sampleRate,
        'channels': channels,
      });
      return result;
    } on PlatformException {
      // 编码失败由调用方明确报错，不再有 WAV 回落
      return null;
    }
  }

  @override
  void dispose() {
    _micStream = null;
    _levelStream = null;
    _eventStream = null;
  }
}
