import 'brain_config.dart';
import 'profile.dart';

// 这两个类原来就住在文件里，拆出去之后仍然从这里导出，
// 免得所有 `import '../config/assistant_config.dart'` 的调用点都要改。
export 'brain_config.dart';
export 'profile.dart';

/// 用户可编辑的全部配置。
///
/// 断句参数对应 Rust 侧的 `SegmenterConfig`（`rust/src/api/vad.rs`）。
/// 名字前缀一律是 `vad`，和那边对不上的地方在 `SileroSegmenter.open` 里映射。
///
/// **断句参数是全局的，不分档案。** 这是有意的取舍：改这些参数意味着重建
/// segmenter（要重新加载 1.26MB 的 ONNX 模型，几百毫秒），而切档案必须是
/// 立刻见效的。真要做成每个档案一套，正确做法是"先切界面、后台异步重建"，
/// 那是另一个量级的事情。
class AssistantConfig {
  const AssistantConfig({
    this.profiles = const <Profile>[],
    this.focusedProfileId = defaultProfileId,
    this.vadThreshold = 0.5,
    this.vadMinSilenceMs = 1000,
    this.vadSpeechPadMs = 200,
    this.vadMinSpeechMs = 300,
    this.vadMaxSpeechS = 60,
    this.vadRingCapacityMs = 70000,
    this.bargeIn = false,
    this.volumeKeyClearsQueue = true,
  });

  /// 从只有 `brain` 字段的老配置迁移出来时，给那个档案的固定 id。
  ///
  /// 用固定值而不是随机值有两个好处：迁移是幂等的（反复解析得到同一个 id），
  /// 以及迁移后的历史目录名是可预期的。
  static const String defaultProfileId = 'default';

  /// 全部档案。**解析之后保证非空** —— 至少有 `default` 一个。
  final List<Profile> profiles;

  /// 当前聚焦的档案 id。
  final String focusedProfileId;

  /// 聚焦的那个档案。
  ///
  /// **只认 id，不做兜底。** 以前这里会退回 `profiles.first`，但那样一来
  /// "谁是聚焦"就有两种说法了：这个 getter 说第一个是，而
  /// [Profile.stateIn] 对谁都说"没聚焦"，界面和 brain 就会指向两个不同的
  /// 档案。让它在 id 对不上时老老实实返回 null，问题会当场暴露而不是
  /// 悄悄走偏。
  ///
  /// 正常路径上它不会是 null：`fromJson` 和 [normalized] 都会把焦点收进
  /// 一个真实存在、且开着的档案。只有 `const AssistantConfig()` 这种
  /// 还没归一化的空配置才是 null。
  Profile? get focusedProfile => _find(focusedProfileId);

  /// 聚焦档案的 brain 配置。
  ///
  /// **保留成计算属性而不是字段**，这样 `config.brain.baseUrl` 这种读了
  /// 一年多的地方一行都不用改，而"brain 配置只存在档案里"这个不变量
  /// 也守住了。
  BrainConfig get brain => focusedProfile?.brain ?? const BrainConfig();

  /// 屏幕上的说话按钮和标题会用到。
  int get accentColor =>
      focusedProfile?.accentColor ?? Profile.defaultAccentColor;

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

  /// 音量减键 = 让它闭嘴。
  ///
  /// **默认开**（保持原行为）。关掉之后音量减就是普通的调音量，
  /// 想清空播放队列走通知栏的「停止说话」按钮。
  ///
  /// 做成开关的原因：AI 正在说话时想"把声音调小一点"和想"让它别说了"
  /// 是两个意图，前者更常见。键被吞掉时音量调不动，用户只会以为手机卡了。
  final bool volumeKeyClearsQueue;

  /// 把某个档案整个换掉（找不到就追加）。改档案配置用这个，别去动列表本身。
  AssistantConfig withProfile(Profile profile) {
    final next = List<Profile>.of(profiles);
    final index = next.indexWhere((p) => p.id == profile.id);
    if (index >= 0) {
      next[index] = profile;
    } else {
      next.add(profile);
    }
    return copyWith(profiles: next);
  }

  /// 删掉一个档案。
  ///
  /// **只动配置，不动盘上的历史。** 历史是用户的东西，删档案不该顺手
  /// 把它清掉 —— 那是另一件要明确确认的事。
  ///
  /// 删的是聚焦的那个时，焦点按列表顺序挪到下一个还启用的档案上；
  /// 一个都不剩就落在空 id 上（此时 `focusedProfile` 是 null）。
  AssistantConfig withoutProfile(String id) {
    final next = profiles.where((p) => p.id != id).toList();
    if (next.isEmpty) return copyWith(profiles: next, focusedProfileId: '');

    var focused = focusedProfileId;
    if (focused == id) {
      focused = next.firstWhere(
        (p) => p.enabled,
        orElse: () => next.first,
      ).id;
    }
    return copyWith(profiles: next, focusedProfileId: focused);
  }

  /// 定位到一个存在的、开着的档案上。
  ///
  /// 三种坏数据都在这里收拾干净：`profiles` 是空的（代码里直接构造了
  /// `const AssistantConfig()`）、`focusedProfileId` 指向一个已经被删掉的
  /// id、以及焦点落在一个被关掉的档案上（关掉正在聚焦的档案时会出现）。
  ///
  /// 把它收干净是为了让下游少一堆判空：归一化之后 `focusedProfile`
  /// 保证非 null（除非所有档案都关着），`brain` 也一定指向一个真实的档案。
  AssistantConfig normalized() {
    if (profiles.isEmpty) {
      // **不能沿用 `defaultProfileId`。** 那是老配置迁移时那个档案的固定
      // id，而"删档案不删历史"意味着盘上 `history/default/` 还在。拿它补一个
      // 回来，刚被删掉的那份历史会原样挂到这个空档案上 —— 用户看到的像是
      // "删不掉"，还顺手把填好的 baseUrl / brain_id 清空了。
      // 换一个没人用过的 id，历史才不会串回来。
      final fresh = Profile(id: Profile.newId());
      return copyWith(profiles: [fresh], focusedProfileId: fresh.id);
    }

    final focused = _find(focusedProfileId);
    if (focused == null) return copyWith(focusedProfileId: profiles.first.id);

    // 关掉的档案什么都不跑，不该还占着焦点。全关着的时候没地方可挪，
    // 就让它待在原地 —— 界面会把它显示成"已关闭"。
    if (!focused.enabled) {
      for (final profile in profiles) {
        if (profile.enabled) return copyWith(focusedProfileId: profile.id);
      }
    }
    return this;
  }

  Profile? _find(String id) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  AssistantConfig copyWith({
    BrainConfig? brain,
    List<Profile>? profiles,
    String? focusedProfileId,
    double? vadThreshold,
    int? vadMinSilenceMs,
    int? vadSpeechPadMs,
    int? vadMinSpeechMs,
    int? vadMaxSpeechS,
    int? vadRingCapacityMs,
    bool? bargeIn,
    bool? volumeKeyClearsQueue,
  }) {
    final nextProfiles = List<Profile>.of(profiles ?? this.profiles);
    var nextFocused = focusedProfileId ?? this.focusedProfileId;

    // 兼容老的调用点（设置页至今在用）：`copyWith(brain: ...)` 的语义是
    // "把聚焦那个档案的 brain 换掉"。档案还不存在就地造一个，
    // 这样第一次填配置的路径不会因为"没有档案"而无处可写。
    if (brain != null) {
      // 焦点可能是个非法 id —— 删光所有档案之后它会是空串。
      // 拿它去造档案会造出一个 id 为空的档案，而这个 id 是要当目录名用的，
      // 落盘之后再读出来会被丢掉，接上存储层还会直接抛。
      if (!Profile.isValidId(nextFocused)) nextFocused = defaultProfileId;

      final index = nextProfiles.indexWhere((p) => p.id == nextFocused);
      if (index >= 0) {
        nextProfiles[index] = nextProfiles[index].copyWith(brain: brain);
      } else {
        nextProfiles.insert(0, Profile(id: nextFocused, brain: brain));
      }
    }

    return AssistantConfig(
      profiles: nextProfiles,
      focusedProfileId: nextFocused,
      vadThreshold: vadThreshold ?? this.vadThreshold,
      vadMinSilenceMs: vadMinSilenceMs ?? this.vadMinSilenceMs,
      vadSpeechPadMs: vadSpeechPadMs ?? this.vadSpeechPadMs,
      vadMinSpeechMs: vadMinSpeechMs ?? this.vadMinSpeechMs,
      vadMaxSpeechS: vadMaxSpeechS ?? this.vadMaxSpeechS,
      vadRingCapacityMs: vadRingCapacityMs ?? this.vadRingCapacityMs,
      bargeIn: bargeIn ?? this.bargeIn,
      volumeKeyClearsQueue: volumeKeyClearsQueue ?? this.volumeKeyClearsQueue,
    );
  }

  /// **存储 key 是 `assistant_config_v1`，不许改。**
  ///
  /// `brain` 这个键新版本**照样写**，值等于当前聚焦档案的 brain。这样用户
  /// 万一回退到旧版 APK，旧代码读 `json['brain']` 拿到的还是能用的
  /// baseUrl / brainId / token，不会静默清空。
  Map<String, dynamic> toJson() => {
        'brain': brain.toJson(),
        'profiles': profiles.map((p) => p.toJson()).toList(),
        'focusedProfileId': focusedProfileId,
        'vadThreshold': vadThreshold,
        'vadMinSilenceMs': vadMinSilenceMs,
        'vadSpeechPadMs': vadSpeechPadMs,
        'vadMinSpeechMs': vadMinSpeechMs,
        'vadMaxSpeechS': vadMaxSpeechS,
        'vadRingCapacityMs': vadRingCapacityMs,
        'bargeIn': bargeIn,
        'volumeKeyClearsQueue': volumeKeyClearsQueue,
      };

  /// 老 JSON 里没有 `profiles` / `focusedProfileId`，靠这里补出来；
  /// 换 key 反而会把用户已经填好的 baseUrl / brainId / token 静默清空。
  factory AssistantConfig.fromJson(Map<String, dynamic> json) {
    final rawProfiles = json['profiles'];
    final profiles = <Profile>[];
    if (rawProfiles is List) {
      for (final item in rawProfiles) {
        if (item is! Map) continue;
        final profile = Profile.fromJson(item.cast<String, dynamic>());
        // id 非法或者重复的整项丢掉。留着重复 id 会让两个档案抢同一份历史。
        if (profile == null || profiles.any((p) => p.id == profile.id)) continue;
        profiles.add(profile);
      }
    }

    if (profiles.isEmpty) {
      // 迁移分支：老配置只有一个 brain 字段，把它原样搬进默认档案。
      final legacy = BrainConfig.fromJson(
        (json['brain'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
      profiles.add(Profile(
        id: defaultProfileId,
        // 名字取 brainId，用户进去就能看到一个具体的名字而不是空白。
        // 但**没填名字**时才取，填了就跟着 brainId 走（displayName 的回退）。
        name: legacy.brainId.trim(),
        brain: legacy,
      ));
    }

    final rawFocused = json['focusedProfileId'];
    final focused = rawFocused is String && profiles.any((p) => p.id == rawFocused)
        ? rawFocused
        : profiles.first.id;

    return AssistantConfig(
      profiles: profiles,
      focusedProfileId: focused,
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
      // 老配置里没有这个键 —— 缺省当作开，行为跟升级前一致。
      // 类型不对也当缺省，不让一个字段把整份配置带崩（那条教训在 Profile 上踩过）。
      volumeKeyClearsQueue:
          json['volumeKeyClearsQueue'] is bool ? json['volumeKeyClearsQueue'] as bool : true,
    );
  }
}
