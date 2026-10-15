/// brain API 配置。
///
/// 注意这里**没有 STT / TTS 的字段** —— 识别和合成都在 brain 那边，
/// 手机只负责采集、切句、上传、播放。
class BrainConfig {
  const BrainConfig({
    this.baseUrl = '',
    this.brainId = '',
    this.token = '',
  });

  /// 例如 http://192.168.0.100:8000。留空则无法开始对话。
  final String baseUrl;

  /// 会话句柄。**像人的名字一样有语义**，由用户起名，不是生成的。
  ///
  /// 状态按名字存在服务端，所以同一个 brain_id 跨 App 重启仍是同一段对话；
  /// 想开一段全新的对话，换个名字就行。
  final String brainId;

  /// Bearer token。**可以为空** —— 表示该部署没启用鉴权，
  /// 此时客户端不发 Authorization 头（而不是发一个空的 `Bearer `）。
  final String token;

  bool get isUsable => baseUrl.trim().isNotEmpty && brainId.trim().isNotEmpty;

  BrainConfig copyWith({String? baseUrl, String? brainId, String? token}) =>
      BrainConfig(
        baseUrl: baseUrl ?? this.baseUrl,
        brainId: brainId ?? this.brainId,
        token: token ?? this.token,
      );

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'brainId': brainId,
        'token': token,
      };

  factory BrainConfig.fromJson(Map<String, dynamic> json) => BrainConfig(
        baseUrl: json['baseUrl'] as String? ?? '',
        brainId: json['brainId'] as String? ?? '',
        token: json['token'] as String? ?? '',
      );
}

/// 用户可编辑的全部配置。
///
/// 断句参数对应 Rust 侧的 `SegmenterConfig`（`rust/src/api/vad.rs`）。
/// 名字前缀一律是 `vad`，和那边对不上的地方在 `SileroSegmenter.open` 里映射。
class AssistantConfig {
  const AssistantConfig({
    this.brain = const BrainConfig(),
    this.vadThreshold = 0.5,
    this.vadMinSilenceMs = 1000,
    this.vadSpeechPadMs = 200,
    this.vadMinSpeechMs = 300,
    this.vadMaxSpeechS = 60,
    this.vadRingCapacityMs = 70000,
    this.bargeIn = false,
  });

  final BrainConfig brain;

  /// Silero 的语音概率阈值（0~1）。调高更保守（不容易被噪声触发），
  /// 调低更容易触发。
  final double vadThreshold;

  /// 静音持续多久算一段说完。**这是修"话没说完就被切"的主参数。**
  ///
  /// crate 默认值是 100ms —— 太短，句内停顿都会被当成结束。
  /// 这里默认 1000ms：700ms 在真机上不够 —— 用户斟酌措辞时停顿一下就
  /// 被切断上传了（"我还在说话呢"）。加到 1 秒后这种误切基本消失，
  /// 代价是每轮说完到上传多等 0.3 秒。
  final int vadMinSilenceMs;

  /// 段两端各外扩多少毫秒。不留的话第一个字会被切掉。
  final int vadSpeechPadMs;

  /// 短于此长度的段直接丢弃（咳嗽一声不触发）。
  ///
  /// 注意比的是**减掉两端外扩之后**的原始跨度，不是切出来的长度。
  final int vadMinSpeechMs;

  /// 说超过这个秒数就强制切段，避免一直说下去永远不结束。
  ///
  /// 这是**强制切**，不管你有没有停顿 —— 说到一半也会被砍，用户看到
  /// 的就是"我话没说完它发出去了"。20 秒真机上确实太短（用户口述一段
  /// 想法很容易超），提到 60 秒。
  final int vadMaxSpeechS;

  /// 环形缓冲保留多久的音频（毫秒）。**必须大于 `vadMaxSpeechS`**，
  /// 否则正在说的那一段会被自己挤掉（开头丢字）。
  ///
  /// Rust 侧 `capacity_for()` 会兜底取
  /// `max(ring_capacity_ms, max_speech_ms + 2*pad + 1000)`，
  /// 所以配小了也不会真的丢 —— 但配置本身该是自洽的。
  /// 60 秒的 16kHz 单声道 PCM16 只占 1.9MB，留到 70 秒没压力。
  final int vadRingCapacityMs;

  /// 打断：你一开口就停掉 AI 正在说的话。
  ///
  /// **默认关**，就是 handoff §A5 的「收到就播，不做自动打断」。
  /// 开与不开是两种不同的产品语义，所以做成显式开关而不是自动判断 ——
  /// 自动判断在双讲场景下必然误判，而误判的代价是 AI 被你自己的声音打断。
  ///
  /// 闭麦开着时它天然失效（音频根本没上去，本地断句听不到任何东西）。
  final bool bargeIn;

  AssistantConfig copyWith({
    BrainConfig? brain,
    double? vadThreshold,
    int? vadMinSilenceMs,
    int? vadSpeechPadMs,
    int? vadMinSpeechMs,
    int? vadMaxSpeechS,
    int? vadRingCapacityMs,
    bool? bargeIn,
  }) =>
      AssistantConfig(
        brain: brain ?? this.brain,
        vadThreshold: vadThreshold ?? this.vadThreshold,
        vadMinSilenceMs: vadMinSilenceMs ?? this.vadMinSilenceMs,
        vadSpeechPadMs: vadSpeechPadMs ?? this.vadSpeechPadMs,
        vadMinSpeechMs: vadMinSpeechMs ?? this.vadMinSpeechMs,
        vadMaxSpeechS: vadMaxSpeechS ?? this.vadMaxSpeechS,
        vadRingCapacityMs: vadRingCapacityMs ?? this.vadRingCapacityMs,
        bargeIn: bargeIn ?? this.bargeIn,
      );

  Map<String, dynamic> toJson() => {
        'brain': brain.toJson(),
        'vadThreshold': vadThreshold,
        'vadMinSilenceMs': vadMinSilenceMs,
        'vadSpeechPadMs': vadSpeechPadMs,
        'vadMinSpeechMs': vadMinSpeechMs,
        'vadMaxSpeechS': vadMaxSpeechS,
        'vadRingCapacityMs': vadRingCapacityMs,
        'bargeIn': bargeIn,
      };

  /// **存储 key 是 `assistant_config_v1`，不许改。**
  ///
  /// 老 JSON 里没有下面这些键，靠默认值兜住即可；换成 v2 反而会把用户
  /// 已经填好的 baseUrl / brainId / token 静默清空。
  factory AssistantConfig.fromJson(Map<String, dynamic> json) => AssistantConfig(
        brain: BrainConfig.fromJson(
          (json['brain'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
        vadThreshold: (json['vadThreshold'] as num?)?.toDouble() ?? 0.5,
        // 旧版本只有一个 vadSilenceMs，读它作为回退，别让用户调过的值丢回默认。
        vadMinSilenceMs: (json['vadMinSilenceMs'] as num?)?.toInt() ??
            (json['vadSilenceMs'] as num?)?.toInt() ??
            1000,
        vadSpeechPadMs: (json['vadSpeechPadMs'] as num?)?.toInt() ?? 200,
        vadMinSpeechMs: (json['vadMinSpeechMs'] as num?)?.toInt() ?? 300,
        vadMaxSpeechS: (json['vadMaxSpeechS'] as num?)?.toInt() ?? 60,
        vadRingCapacityMs: (json['vadRingCapacityMs'] as num?)?.toInt() ?? 70000,
        bargeIn: json['bargeIn'] as bool? ?? false,
      );
}
