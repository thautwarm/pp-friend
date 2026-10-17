import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../audio/pcm_utils.dart';
import '../audio/segmenter.dart';
import '../audio/silero_segmenter.dart';
import '../audio/test_tone.dart';
import '../brain/brain_client.dart';
import '../config/assistant_config.dart';
import '../config/config_store.dart';
import '../storage/app_dirs.dart';
import '../storage/avatar_store.dart';
import '../storage/file_message_store.dart';
import '../storage/memory_message_store.dart';
import '../storage/message_store.dart';
import '../storage/voiceprint_store.dart';
import '../voice/voice_engine.dart';
import 'message.dart';
import 'profile_runtime.dart';
import 'utterance_queue.dart';

/// 已经收到、还没轮到播的一条回复。
///
/// **取和播分成两条线**之后才有这个东西：轮询那条只管拿，拿到就往这里塞，
/// 塞完立刻再去问下一条；播的循环从队头取一条播一条。队列里的东西是
/// "已经拿到手、但用户还没听到"的 —— 被清掉时整条算没听到，正是
/// `unheard_text` 的第二项。
class _PendingReply {
  _PendingReply({required this.text, required this.audio, required this.spans});

  final String text;

  /// 原始 Ogg Opus，**还没解码**。到真要播的时候才解 ——
  /// 万一这条在队列里就被清掉，解码白做。
  final Uint8List audio;

  final List<BrainSpan> spans;
}

class LogEntry {
  LogEntry(this.message) : at = DateTime.now();

  final String message;
  final DateTime at;

  String get time {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }
}

/// 编排整条链路。
///
/// 有**两条互相独立的循环**，这是协议本身决定的：
///
///   A  麦克风 → 本地断句（Rust/Silero VAD）→ 串行队列 → POST /human-to-brain → 文本进消息流
///   B  持续 POST /brain-to-human（阻塞）→ 有内容就进消息流 + 解码播放
///
/// 载荷是 MessagePack，不是 JSON 也不是 multipart。
///
/// 它们不互相等待：你说的话可能在 AI 开口之前才刚拿到文本，
/// 也可能 AI 主动说话而你什么都没说。所以消息流只按时间排序。
///
/// **打断默认不做**，收到就播。开了「打断」开关（[bargeIn]）之后，
/// 你一开口就停掉它。不开时清空 AI 语音是手动动作（通知栏「停止说话」
/// 按钮，或前台的音量减键）。文本永远进消息流，只有音频会被清掉 ——
/// 而且被打断时要告诉 brain「我听到哪儿了」，否则它下一轮会接着
/// 「刚才说的那个」往下讲，用户只能装懂。
/// 造一个 [Segmenter]。只为了让 `flutter test` 能注入假实现 ——
/// 生产实现要加载 `.so`，host 上跑不起来。
typedef SegmenterFactory = Future<Segmenter> Function({
  required int sampleRate,
  required AssistantConfig config,
});

class ConversationController extends ChangeNotifier {
  ConversationController({
    VoiceEngine? engine,
    ConfigStore? store,
    BrainClient? brain,
    BrainClient Function()? brainFactory,
    MessageStore? history,
    AppDirResolver? appDir,
    AvatarStore? avatars,
    SegmenterFactory? segmenterFactory,
  })  : _engine = engine ?? VoiceEngine.instance,
        _store = store ?? ConfigStore(),
        _brainFactory =
            brainFactory ?? (brain == null ? BrainClient.new : () => brain),
        _injectedHistory = history,
        _injectedAvatars = avatars,
        _appDirResolver = appDir ?? resolveAppDir,
        _segmenterFactory = segmenterFactory ?? _defaultSegmenterFactory;

  static Future<Segmenter> _defaultSegmenterFactory({
    required int sampleRate,
    required AssistantConfig config,
  }) =>
      SileroSegmenter.open(inputSampleRate: sampleRate, config: config);

  final VoiceEngine _engine;
  final ConfigStore _store;

  /// 造一个 brain 客户端。**每个档案要各自的实例**。
  ///
  /// 传了 `brain:` 的话工厂永远返回同一个实例，只适合单档案的场景
  /// （现有的测试就是这么用的）。多档案共用一个是错的：
  /// [BrainClient.abort] 会把底层 client 关掉重开，那会把别的档案
  /// 在途的长轮询一起打断。
  final BrainClient Function() _brainFactory;

  /// 测试注入的历史存储。不注入就按应用目录造一个真的。
  final MessageStore? _injectedHistory;

  /// 测试注入的头像存储。
  ///
  /// 有它是因为**头像全是文件操作**，而 `testWidgets` 会把测试体跑在一个
  /// 假的时钟里，真实的磁盘 IO 在那里永远不会完成 —— 界面测试一旦碰到
  /// 真的 `File`，整个测试就挂住，而不是报错。和 [MessageStore] 配
  /// `MemoryMessageStore` 是同一个道理。
  final AvatarStore? _injectedAvatars;
  final AppDirResolver _appDirResolver;
  final SegmenterFactory _segmenterFactory;

  MessageStore? _history;

  /// 解析出来的应用目录。历史、头像都挂在它下面。
  ///
  /// 留着它是因为头像不走 [MessageStore]（那是消息的抽象，不该塞图片进去），
  /// 但**目录解析必须只有一处真相** —— 让界面自己去调 path_provider 拼路径，
  /// 迟早会和历史目录跑偏。
  Directory? _appRoot;

  /// 声纹存储。拿不到应用目录时是 null（此时说话人识别不可用）。
  VoiceprintStore? get voiceprintStore {
    final root = _appRoot;
    return root == null ? null : VoiceprintStore(root);
  }

  /// 盘上有没有声纹。设置页拿它决定显示"已导入"还是"未导入"。
  bool get hasVoiceprint => _hasVoiceprint;
  bool _hasVoiceprint = false;

  /// 头像存储。拿不到应用目录（降级到内存）时是 null。
  AvatarStore? get _avatars {
    final injected = _injectedAvatars;
    if (injected != null) return injected;
    final root = _appRoot;
    return root == null ? null : AvatarStore(root);
  }

  /// 拿不到应用目录，退化成内存存储了。界面要据此提示用户。
  bool get historyDegraded => _historyDegraded;
  bool _historyDegraded = false;

  static const int logLimit = 120;

  /// 双讲判据的余量：麦克风电平要比播放电平高这么多，才算"真的是你在说"。
  static const double doubleTalkMarginDb = 6;

  bool _disposed = false;

  /// 给运行态用的回调。
  ///
  /// 档案的轮询是**独立的一条线**，它可能在 controller 已经 dispose 之后
  /// 才跑完最后一次循环。直接挂 `notifyListeners` 的话，那一次回调会打在
  /// 一个已经销毁的 ChangeNotifier 上，debug 模式下直接抛断言。
  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }

  void _safeLog(String message) {
    if (_disposed) return;
    _append(message);
  }

  // ---------------------------------------------------------------- 配置

  AssistantConfig _config = const AssistantConfig();
  AssistantConfig get config => _config;

  DebugAudioProfile _debugProfile = const DebugAudioProfile();
  DebugAudioProfile get debugProfile => _debugProfile;

  Future<void> loadConfig() async {
    _config = (await _store.load()).normalized();
    await _syncRuntimes();
    await refreshVoiceprint();
    // 先把聚焦档案的历史读出来，这样一打开 App 就看得见上次聊到哪儿了，
    // 不用等到点"开始对话"。
    await focused?.load();
    notifyListeners();
  }

  Future<void> updateConfig(AssistantConfig config) async {
    final previousFocus = _config.focusedProfileId;
    final next = config.normalized();

    // 焦点被这份新配置挪走了（正在聚焦的档案被关掉/删掉）—— 和手动切换
    // 一样，先把旧档案的账结掉、把声音停掉再换。**不这么做的话，关掉一个
    // 正在说话的档案，它的声音会接着播完**，而没听完的那几句会被记到
    // 新档案头上。这一步必须在 `_config` 被替换之前做：结账认的是"此刻
    // 聚焦的那个"。
    if (next.focusedProfileId != previousFocus) {
      await _settleBeforeLeavingFocus();
    }

    final volumeKeyChanged =
        next.volumeKeyClearsQueue != _config.volumeKeyClearsQueue;
    final pvadChanged = next.pvadEnabled != _config.pvadEnabled ||
        next.pvadThreshold != _config.pvadThreshold ||
        next.pvadMinTargetRatio != _config.pvadMinTargetRatio;

    _config = next;
    if (pvadChanged) {
      // 门控是挂在活着的断句器上的，改完立刻重挂 —— 不用重开对话。
      await _applySpeakerGate();
    }
    if (volumeKeyChanged) {
      // 按键是原生侧收的，它看不到配置 —— 改了就得推一次。
      await _engine.setVolumeKeyClearsQueue(next.volumeKeyClearsQueue);
    }
    await _syncRuntimes();
    // 焦点被 config 改掉了（删掉正在聚焦的档案、关掉它、或者直接改
    // focusedProfileId），新聚焦那个档案的历史得读进来。消息窗口是懒加载的，
    // 不主动读的话切过去会看到一片空白。
    if (_config.focusedProfileId != previousFocus) {
      await focused?.load();
    }
    notifyListeners();
    await _store.save(_config);
  }

  /// 拿历史存储。拿不到应用目录就退化成内存版，并且**记下来**。
  ///
  /// 静默退化到"看着有历史其实没有"是不可接受的：用户会以为东西存住了，
  /// 重启之后才发现全没了。
  Future<MessageStore> _ensureHistory() async {
    final existing = _history;
    if (existing != null) return existing;

    final injected = _injectedHistory;
    if (injected != null) return _history = injected;

    final dir = await _appDirResolver();
    if (dir == null) {
      _historyDegraded = true;
      _append('⚠️ 拿不到应用目录，历史只留在内存里，重启就没了');
      return _history = MemoryMessageStore();
    }
    _appRoot = dir;
    return _history = FileMessageStore(
      root: dir,
      onWarn: (message) => _append('⚠️ $message'),
    );
  }

  // ---------------------------------------------------------------- 声纹

  /// 重新检查盘上有没有声纹。设置页打开时、导入/删除之后各调一次。
  Future<void> refreshVoiceprint() async {
    final store = voiceprintStore;
    final present = store != null && await store.exists();
    if (present == _hasVoiceprint) return;
    _hasVoiceprint = present;
    _safeNotify();
  }

  /// 导入声纹。格式不对抛 [FormatException]，界面负责显示原因。
  ///
  /// 会话正在进行时立刻生效：挂门控只加一个推理节点，不用重建断句器。
  Future<void> importVoiceprint(Uint8List bytes) async {
    final store = voiceprintStore;
    if (store == null) throw StateError('拿不到应用目录，声纹存不下来');
    final voiceprint = Voiceprint.parse(bytes);
    await store.save(voiceprint);
    _hasVoiceprint = true;
    _append('声纹已导入（192 维）');
    await _applySpeakerGate();
    _safeNotify();
  }

  Future<void> removeVoiceprint() async {
    final store = voiceprintStore;
    if (store == null) return;
    await store.clear();
    _hasVoiceprint = false;
    _segmenter?.detachSpeakerGate();
    _append('声纹已删除 —— 所有说话人都会被上传');
    _safeNotify();
  }

  /// 配置里的说话人识别开关变了之后重新挂一次。
  Future<void> _applySpeakerGate() async {
    final segmenter = _segmenter;
    if (segmenter == null) return;
    await _attachSpeakerGate(segmenter);
  }

  Future<void> _attachSpeakerGate(Segmenter segmenter) async {
    if (!_config.pvadEnabled) {
      segmenter.detachSpeakerGate();
      return;
    }
    final store = voiceprintStore;
    final voiceprint = store == null ? null : await store.load();
    if (voiceprint == null) {
      _append('说话人识别：还没导入声纹，所有声音都会上传');
      return;
    }
    // FNV-1a 指纹：用来确认"现在导入的是哪一份声纹"，只用于日志。
    var fp = 0x811c9dc5;
    for (final b in voiceprint.bytes) {
      fp = ((fp ^ b) * 0x01000193) & 0xffffffff;
    }
    debugPrint('SPK attach fp=${fp.toRadixString(16)} '
        'cos>=${_config.pvadMinCosine}');
    final ok = await segmenter.attachSpeakerGate(
      voiceprint.bytes,
      threshold: _config.pvadThreshold,
      minTargetRatio: _config.pvadMinTargetRatio,
      minCosine: _config.pvadMinCosine,
    );
    if (ok) {
      _append('说话人识别已启用：只上传本人的声音'
          '（声纹相似度 ≥ ${_config.pvadMinCosine.toStringAsFixed(2)}）');
    } else {
      final why = segmenter.speakerGateError;
      _append('⚠️ 说话人识别没挂上${why == null ? '' : '：$why'}');
    }
  }

  /// 被门控丢掉的段。日志节流一下：一家人聊天时它会一直触发，
  /// 每条都写会把 120 条的事件环刷没。
  int _filteredLogCount = 0;

  void _onFilteredSegment(FilteredSegment segment) {
    debugPrint('SPK drop ${segment.durationMs}ms '
        'cos=${segment.speakerCos.toStringAsFixed(3)} '
        'pvad=${segment.pvadScore.toStringAsFixed(3)} '
        'ratio=${segment.pvadTargetRatio.toStringAsFixed(2)}');
    _filteredLogCount++;
    if (_filteredLogCount % 5 != 1) return;
    final detail = segment.speakerCos >= 0
        ? '声纹 cos ${segment.speakerCos.toStringAsFixed(2)}'
        : '本人占比 ${(segment.pvadTargetRatio * 100).round()}%';
    _append('说话人不是本人，丢掉一段 ${segment.durationMs}ms（$detail）');
  }

  /// 让运行态和配置对齐：新建缺的、丢掉多余的、更新改过的。
  ///
  /// 配置可以从好几个地方变（设置页存盘、关掉某个档案、删除档案），
  /// 集中在这里收口，免得每个改配置的地方都要自己记得同步。
  Future<void> _syncRuntimes() async {
    final history = await _ensureHistory();
    final wanted = <String, Profile>{
      for (final profile in _config.profiles) profile.id: profile,
    };

    for (final id in _runtimes.keys.toList()) {
      if (wanted.containsKey(id)) continue;
      final gone = _runtimes.remove(id)!;
      await gone.dispose();
    }

    for (final entry in wanted.entries) {
      final existing = _runtimes[entry.key];
      if (existing == null) {
        _runtimes[entry.key] = ProfileRuntime(
          profile: entry.value,
          brain: _brainFactory(),
          store: history,
          onChanged: _safeNotify,
          onLog: _safeLog,
          isActive: () => _active,
          // 现读，不缓存：焦点随时可能被换掉（滑动、关闭档案、删档案）
          isFocused: () => _config.focusedProfileId == entry.key,
          onReply: _enqueueReply,
        );
      } else {
        existing.updateProfile(entry.value);
      }
    }

    await _syncPolling();
  }

  /// 按每个档案的状态决定它那条轮询该不该跑。
  ///
  /// 关闭的档案不轮询；会话没开始（或者已经结束）时谁都不跑。
  ///
  /// 还没填 brain 的档案也不轮询：新建的档案默认是开着的，地址还没填就要
  /// 去连，会以 15 秒的退避一路空转到用户填好为止 —— 那是纯粹的耗电和
  /// 服务端噪音。填好之后 [updateConfig] 会重新走到这里把它拉起来。
  Future<void> _syncPolling() async {
    for (final runtime in _runtimes.values) {
      final shouldRun =
          _active && runtime.profile.enabled && runtime.profile.brain.isUsable;
      if (shouldRun) {
        if (!runtime.running) runtime.startPolling();
      } else {
        await runtime.stopPolling();
      }
    }
  }

  // ---------------------------------------------------------------- 状态

  bool _active = false;
  bool get active => _active;

  bool _busy = false;
  bool get busy => _busy;

  AudioFormat? _format;
  AudioFormat? get format => _format;

  /// 本地断句认为你正在说话。
  bool _userSpeaking = false;
  bool get userSpeaking => _userSpeaking;

  /// AI 正在出声。
  bool _speaking = false;

  /// 耳朵里还有声音吗。
  ///
  /// **不能只看 [_speaking]。** 它只表示 Dart 侧的推送循环还在跑：整条回复
  /// 早就排进 AudioTrack 的缓冲了，推送循环在声音放完之前就结束了 ——
  /// 于是"AI 还在说"的绝大部分时间里 `_speaking` 都是 false。
  /// 只看它的话，打断永远不触发（`_shouldMuteMic` 的双讲门、标题行、
  /// 听写状态也一起失灵）。缓冲里还有没播完的，就是还在说。
  bool get speaking => _speaking || _backlogFrames > 0;

  /// 上行是否在用 Opus。启动时运行时探测一次。
  bool _opusUpstream = false;
  bool get opusUpstream => _opusUpstream;

  final ValueNotifier<AudioLevels> levelsNotifier =
      ValueNotifier(const AudioLevels(micDb: -120, playbackDb: -120));

  final List<LogEntry> _log = <LogEntry>[];
  List<LogEntry> get log => List.unmodifiable(_log);

  int _droppedMicFrames = 0;
  int get droppedMicFrames => _droppedMicFrames;

  int _backlogFrames = 0;
  int get backlogFrames => _backlogFrames;

  int get queuedUtterances => _speakQueue?.pendingCount ?? 0;
  int get droppedUtterances => _speakQueue?.dropped ?? 0;

  // ---------------------------------------------------------------- 档案

  /// 每个档案一个运行态。
  ///
  /// 下面那几个转发 getter（[messages] / [polling] / [brainError]…）一律
  /// 读**聚焦的那个**。这样界面和现有测试都不用改 —— 它们本来就只关心
  /// "我正在看的这个档案"。
  final Map<String, ProfileRuntime> _runtimes = <String, ProfileRuntime>{};

  ProfileRuntime? get focused => _runtimes[_config.focusedProfileId];

  /// 聚焦档案的消息流。
  List<ConversationMessage> get messages =>
      focused?.messages ?? const <ConversationMessage>[];

  bool get polling => focused?.polling ?? false;

  /// 最近一次 brain 失败的原因。成功一次就清掉。
  ///
  /// 网络抖动本来就不该往外抛（协议层没有错误响应），但让用户完全看不见
  /// 也不对 —— brain 连不上时主界面停在"正在听你说"是骗人的。
  /// 鉴权失败则必须显式提示，那属于配置错误。
  String? get brainError => focused?.error;

  bool get authFailed => focused?.authFailed ?? false;

  /// 盘上还有更早的历史没读进来。
  bool get hasMoreBefore => focused?.hasMoreBefore ?? false;

  /// 最新一条的 seq。界面靠它判断"是不是来了新消息"。
  int get lastSeq => focused?.lastSeq ?? 0;

  /// 往上翻一页更早的历史。
  Future<void> loadOlder() => focused?.loadOlder() ?? Future<void>.value();

  /// 聚焦档案的历史已经从盘上读过了没有。
  ///
  /// 界面靠它区分"**确实没有**历史"和"历史还没读出来"：少了这个标志，
  /// 冷启动会先闪一句"直接说话就行"，下一帧历史才冒出来。
  bool get historyLoaded => focused?.loaded ?? false;

  /// 某个档案头像的绝对路径。没设头像、或者拿不到应用目录，返回 null。
  ///
  /// **同步、不查文件**：这个方法会在每帧 build 里被调用。文件真丢了
  /// 由 `Image` 的 errorBuilder 退回图标。
  String? avatarPathOf(Profile profile) => _avatars?.pathOf(profile.avatarFile);


  /// 切换的串行队列。见 [switchProfile]。
  Future<void> _switchQueue = Future<void>.value();

  /// 把焦点挪到另一个档案上。
  ///
  /// 正在播的声音**立刻停**（用户明确要求）。
  ///
  /// **音频不重启**：麦克风、断句引擎、前台服务、电平表全都和档案无关，
  /// 切档案换掉的只是"数据从哪儿来、往哪儿去"。切的时候 segmenter 可能正
  /// 处在"你说了半句"的中间态，那半句会照常切出来发给新档案 —— 这不算串流，
  /// 你确实是在切换之后说的那句话。
  ///
  /// **切换是排队的。** 滑得快的时候会有两次切换重叠：结账和留痕发生在
  /// 几个 await 之后，那时候焦点可能已经被另一次切换改掉了 —— A 没听完的
  /// 那笔账会记到 C 头上，C 还会平白多一条"切走的时候这条没播完"。
  /// 排队之后每次切换都在前一次收敛之后再跑，账目和留痕都落在正确的人头上。
  Future<void> switchProfile(String id) {
    final next = _switchQueue.then((_) => _switchProfileNow(id));
    // 队列自己吞掉异常：一次失败不该让后面每一次切换都跟着失败。
    // （返回给调用方的仍然是会抛的那一个。）
    _switchQueue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _switchProfileNow(String id) async {
    if (id == _config.focusedProfileId) return;
    final runtime = _runtimes[id];
    // 关掉的档案不能被聚焦：它什么都不跑，聚过去只会是一片沉默。
    if (runtime == null || !runtime.profile.enabled) return;

    // 进函数就把"从哪儿切走"钉死。后面几个 await 期间焦点可能被别的
    // 调用改掉，结账和留痕必须落在这个快照上。
    final from = _config.focusedProfileId;

    // 旧档案没听完的那笔账先结掉，声音也停掉。**此刻焦点还指着它**，
    // 所以"没听到的那些字"会记到它头上 —— 那些字确实是它说的，下次跟它
    // 说话时该报给它，而不是报给刚切过来的这个。
    await _settleBeforeLeavingFocus();

    if (_config.focusedProfileId != from) return; // 焦点已经被别人改掉了

    _config = _config.copyWith(focusedProfileId: id);
    notifyListeners();

    // 换一整屏历史。后台那段时间攒的消息没有进内存窗口，所以要重新读盘。
    await runtime.load();
    notifyListeners();

    await _store.save(_config);
  }

  /// 新建或者更新一个档案。
  ///
  /// 改配置一律走 `updateConfig`，让 [_syncRuntimes] 收口 —— 不这样
  /// 的话，每个改配置的地方都得自己记得同步运行态。
  Future<void> saveProfile(Profile profile) =>
      updateConfig(_config.withProfile(profile));

  /// 删掉一个档案。
  ///
  /// **盘上的历史不跟着删** —— 那是用户的东西，删一个配置项不该顺手把它清掉。
  /// 历史占的空间由设置页的"清空历史"单独负责。
  ///
  /// 头像删掉：没有档案再引用它了，留在盘上就是一份永远没人认得的垃圾。
  Future<void> removeProfile(String id) async {
    final index = _config.profiles.indexWhere((p) => p.id == id);
    if (index < 0) return;
    final avatar = _config.profiles[index].avatarFile;
    await updateConfig(_config.withoutProfile(id));
    // 有别的档案引用同一个文件就别删（配置被手工改过才可能出现）
    final stillUsed = _config.profiles.any((p) => p.avatarFile == avatar);
    if (!stillUsed) await _avatars?.remove(avatar);
  }

  /// 按 id 找当前配置里的档案。找不到返回 null。
  Profile? _profileById(String id) {
    final index = _config.profiles.indexWhere((p) => p.id == id);
    return index < 0 ? null : _config.profiles[index];
  }

  /// 给某个档案换头像。传 null 表示去掉头像。
  ///
  /// 文件操作放在 controller 里而不是设置页：目录解析的唯一真相在
  /// [_ensureHistory]，界面自己拼路径迟早会和历史目录跑偏。
  ///
  /// 失败（图读不到、目录写不了）**会抛** —— 静默失败比不换更糟，
  /// 用户会以为换好了。
  ///
  /// **写回前重新取一次档案。** 拷贝图片是个文件操作，中间可能过了几十
  /// 毫秒，这期间设置页可能已经把别的字段（名字、brain、开关）存进去了；
  /// 拿进函数时的快照写回，会把这些改动悄悄回滚掉。
  Future<void> setAvatar(String profileId, String? sourcePath) async {
    if (_profileById(profileId) == null) return;
    final store = _avatars;
    if (store == null) {
      throw const FileSystemException('拿不到应用目录，头像存不住');
    }

    if (sourcePath == null) {
      final current = _profileById(profileId);
      if (current == null) return;
      await saveProfile(current.copyWith(clearAvatar: true));
      await store.remove(current.avatarFile);
      return;
    }

    // 先把新图拷进来再改配置：反过来做的话，拷贝失败会让配置里留一个
    // 指向不存在文件的 avatarFile，界面上就是"换了头像但显示不出来"。
    final name = await store.import(profileId, sourcePath);
    final current = _profileById(profileId);
    if (current == null) {
      // 拷贝期间档案被删了。图已经落盘，但没人引用它了，收掉。
      await store.remove(name);
      return;
    }
    await saveProfile(current.copyWith(avatarFile: name));
    if (current.avatarFile != name) await store.remove(current.avatarFile);
  }

  /// 清掉某个档案的全部历史（盘上和内存一起）。
  Future<void> clearHistory(String id) async {
    await _runtimes[id]?.clearHistory();
  }

  /// 这个档案的历史占多少字节。0 表示没有历史或者读不到。
  Future<int> historyBytes(String id) async {
    try {
      return await (await _ensureHistory()).sizeBytes(id);
    } catch (_) {
      return 0;
    }
  }

  // ---------------------------------------------------------------- 内部

  Segmenter? _segmenter;
  UtteranceQueue? _speakQueue;

  /// 复用一块全零缓冲喂"静音"。帧长在一次会话里是恒定的，所以只会分配一次。
  Uint8List? _silenceBuf;

  /// 断句引擎加载失败的原因。
  ///
  /// 能量 VAD 已经删了，加载不出来就是彻底不能用 —— 必须让用户看见，
  /// 不能只在日志里留一行然后白屏。
  String? _segmenterError;
  String? get segmenterError => _segmenterError;

  String? get segmenterName => _segmenter?.name;

  SegmenterStats get segmenterStats =>
      _segmenter?.stats ?? SegmenterStats.idle;

  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<AudioLevels>? _levelSub;
  StreamSubscription<EngineEvent>? _eventSub;
  Timer? _statsTimer;

  /// 播放代号。清空队列时自增，用来作废在途的音频分块。
  int _playbackEpoch = 0;

  /// 由 App 注入的权限申请钩子。返回 false 表示用户拒绝，直接不启动。
  Future<bool> Function()? permissionGate;

  // ---------------------------------------------------------------- 闭麦 / 打断

  /// 闭麦：采到的音频**完全不上传**，不是"上传了再撤"。
  ///
  /// 只在会话内有效，不进配置 —— 下次启动必须回到"在听"，
  /// 否则用户会遇到"我说话它毫无反应"却查不出原因。
  bool _micMuted = false;
  bool get micMuted => _micMuted;

  /// 这一轮闭麦累计了多少毫秒。解除时据此在消息流里留一条痕。
  int _mutedMs = 0;

  /// 闭麦短于这个时长不留痕 —— 手指一抖点两下的噪声没必要写进消息流。
  static const int muteTraceMinMs = 500;

  /// 打断要连续说够这么久才算数（毫秒）。
  ///
  /// Silero 一判到有声就把 `speaking` 立起来，而且那个标志会一直扛到整段
  /// 收尾（要静满 `vadMinSilenceMs` 才落回）—— **跟这段有多长无关**。
  /// 所以咳嗽一声、清个嗓子、叹口气，都是一"开口"就把 AI 打断。
  /// 350ms 是"嗯""啊"这种语气词的量级以下、一个短词以上。
  static const int bargeInMinSpeechMs = 350;

  /// 这一轮连续"够格的语音"累计了多少毫秒。
  int _speechRunMs = 0;

  /// 这一轮已经为打断出手过了，别重复打断。
  bool _bargeInFired = false;

  /// 断句点。按比例估位置时往后找最近的这些字符，别把句子劈开。
  static const String _sentenceBreaks = '。！？；.!?;\n，,、';

  /// 「上一段听到多少毫秒」和「没听到的那部分文字」这两笔账**在档案身上**
  /// （`ProfileRuntime.pendingHeardMs` / `pendingUnheardText`）。
  ///
  /// 挂在 controller 上的话，在 A 里打断攒下的账会跟着下一次上传发给 B ——
  /// 因为下一次上传时读的是"当前聚焦那个档案"的账。这是整个改造里最隐蔽的
  /// 一个 bug，专门有测试盯着。

  /// 正在播的这条回复的时间账（brain 给的，**可能为空**）。
  /// 有它就精确到句；没有就退回按比例估。
  List<BrainSpan> _replySpans = const <BrainSpan>[];

  /// 正在播的这条回复的全文和音频总长（毫秒）。
  /// brain 没给时间账时，靠这两个按比例估"断在哪个字"。
  String _replyText = '';
  int _replyTotalMs = 0;

  /// 已收到、还没轮到播的回复。队头正在播。
  ///
  /// **取和播是两条线**：轮询循环只管把拿到的塞进来，塞完立刻再问；
  /// 播的循环单独跑，从队头取一条播一条。这样两条回复之间没有"等下一次
  /// 网络往返"的空隙，队列也成了一个真的东西 —— 被清掉时，里面还没轮到
  /// 播的整条都算用户没听到。
  final List<_PendingReply> _replyQueue = <_PendingReply>[];

  /// 队列上限。轮询比播放快得多时兜底，免得对面一口气灌进来把内存吃光。
  static const int replyQueueLimit = 4;

  /// 队列的"有东西了"信号。播放循环空转时挂在这上面。
  Completer<void>? _queueSignal;

  Future<void>? _playbackTask;

  /// 这条回复开播时的播放头。播放头会被"清空"归零，
  /// 减掉基线才是"这条回复里听到了多少"。
  int _replyHeadBaseMs = 0;

  /// 打断开关（存在配置里）。开了才在用户开口时停掉 AI。
  bool get bargeIn => _config.bargeIn;

  /// 闭麦开关。帧在本地就被换成数字静音，一个字节都到不了 brain。
  ///
  /// 闭麦期间打断天然失效 —— 本地断句根本听不到东西。这不是 bug，
  /// 文案里要写清楚，否则会被当成故障。
  void setMicMuted(bool muted) {
    if (_micMuted == muted) return;
    _micMuted = muted;
    if (muted) {
      _mutedMs = 0;
      _append('闭麦：采到的音频不会上传，打断也随之失效');
    } else {
      _append('解除闭麦');
      _flushMuteTrace();
    }
    notifyListeners();
  }

  void toggleMicMuted() => setMicMuted(!_micMuted);

  /// 闭麦结束（解除或收尾）时在消息流里留一条痕。
  ///
  /// 静默的开关最吓人：不写一行的话，用户事后分不清刚才那几句
  /// 是闭麦期间说的，还是压根没被识别到。
  void _flushMuteTrace() {
    final ms = _mutedMs;
    _mutedMs = 0;
    if (ms < muteTraceMinMs) return;
    _addMessage(
      MessageRole.note,
      '闭麦中的 ${(ms / 1000).toStringAsFixed(1)}s 没发出去',
    );
  }

  // ---------------------------------------------------------------- 开关

  Future<void> start() async {
    if (_active || _busy) return;
    _busy = true;
    notifyListeners();

    try {
      _log.clear();
      _filteredLogCount = 0;
      // **消息流不清。** 它在 loadConfig 时已经从盘上读回来了，这里只要
      // 别破坏它就行 —— 上次聊过的内容，这次打开还在。
      _append('开始对话');

      final gate = permissionGate;
      if (gate != null && !await gate()) {
        _append('麦克风或通知权限被拒绝，无法开始');
        return;
      }

      final brain = _config.brain;
      if (!brain.isUsable) {
        _append('brain 地址或 brain_id 没填，去配置页补上');
        return;
      }
      _append('brain：${brain.baseUrl} / id=${brain.brainId}'
          '${brain.token.trim().isEmpty ? "（未启用鉴权）" : "（已带 token）"}');

      // 顺序有讲究：前台服务必须在 App 前台时启动；音频配置要在
      // startAudio 之前应用，因为它决定采集源和播放属性。
      await _engine.startService();
      _append('前台服务已启动，可切到其他应用或锁屏');

      await _engine.applyDebugProfile(_debugProfile);

      // 音量键的归属也归配置文件管，原生侧默认是"拦"。这里是**无条件推一次**：
      // 原生那个布尔活在进程里，热重启 Flutter 侧不会重置它 —— 只推"变化"
      // 的话，用户关掉开关后重开一次会话，值又回到原生的默认了。
      await _engine.setVolumeKeyClearsQueue(_config.volumeKeyClearsQueue);

      final format = await _engine.startAudio();
      _format = format;
      _append('音频链路已开启：$format');

      // 运行时探测上行编码能力。
      // minSdk 已是 29，但**仍然探测**：OEM 差异真实存在，
      // 不是所有 API 29+ 的机器都一定有 Opus 编码器。
      _opusUpstream = await _engine.opusEncoderAvailable();
      _append(_opusUpstream
          ? '上行编码：Ogg Opus'
          : '⚠️ 本机没有 Opus 编码器，语音发不出去（规范只收 Ogg Opus）');

      // 顺序有讲究：**必须在订阅 micPcm 之前**建好 segmenter。
      // 加载 1.26MB 模型 + ONNX 图优化是几十到几百毫秒，落在第一帧上
      // 就是一段丢音，而且是从一开始就丢。
      if (!await _openSegmenter(format.sampleRate)) {
        await _teardown();
        return;
      }

      _speakQueue = UtteranceQueue(onSend: _sendUtterance);

      _micSub = _engine.micPcm.listen(_onMicFrame);
      _levelSub = _engine.levels.listen(_onLevels);
      _eventSub = _engine.events.listen(_onEngineEvent);

      _statsTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => unawaited(_refreshStats()),
      );

      _playbackEpoch = 0;
      _replyQueue.clear();
      _active = true;

      // 两条线各跑各的：一条只管取，一条只管播。取的那条拿到就往队列里塞，
      // 不等播完 —— 回话之间的空隙因此只剩网络本身。
      _playbackTask = _playbackLoop();

      // 每个开着档案各起一条轮询，独立跑，不阻塞 start()
      await _syncPolling();
    } catch (e) {
      _append('启动失败：$e');
      await _teardown();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (!_active && !_busy) return;
    _busy = true;
    notifyListeners();
    try {
      await _teardown();
      _append('对话已结束');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> toggle() => _active ? stop() : start();

  // ---------------------------------------------------------------- 循环 A：采集 → /human-to-brain

  /// 建断句引擎。失败就返回 false，由调用方决定怎么收场。
  ///
  /// 这里**不吞异常**：能量 VAD 已删，没有任何可回退的断句手段，
  /// 静默降级等于"点了开始但永远不认你说话"。
  Future<bool> _openSegmenter(int sampleRate) async {
    _segmenter?.dispose();
    _segmenter = null;
    try {
      _segmenter = await _segmenterFactory(
        sampleRate: sampleRate,
        config: _config,
      );
      _segmenterError = null;
      _append('本地断句：${_segmenter!.name}'
          '（静音判定 ${_config.vadMinSilenceMs}ms / 阈值 ${_config.vadThreshold}）');
      // 声纹门控是可选的：挂不上只记一行日志，不能连累断句。
      await _attachSpeakerGate(_segmenter!);
      return true;
    } catch (e) {
      _segmenterError = '本地断句引擎加载失败：$e';
      _append('⚠️ $_segmenterError');
      _append('Rust 动态库没打进包，或 ABI 不匹配。所有 ABI 都没降级方案。');
      return false;
    }
  }

  void _onMicFrame(Uint8List frame) {
    final segmenter = _segmenter;
    if (segmenter == null) return;

    if (_micMuted) {
      final rate = _format?.sampleRate ?? 16000;
      // 16bit 单声道：每毫秒 rate/500 个字节
      _mutedMs += frame.length * 500 ~/ rate;
    }

    try {
      segmenter.feed(
        (_micMuted || _shouldMuteMic()) ? _silence(frame.length) : frame,
        onSpeechStart: _onSpeechStart,
        onUtterance: _onUtterance,
        onFiltered: _onFilteredSegment,
      );
      _trackSpeechRun(segmenter.stats, frame.length);
    } catch (e) {
      // 每帧都会走这里，日志会被刷屏 —— 出一次就收手。
      _append('⚠️ 切句失败：$e');
      unawaited(stop());
    }
  }

  void _onSpeechStart() {
    _userSpeaking = true;
    notifyListeners();
  }

  /// 盯着"这一轮到底连续说了多久"，够久了才让打断出手。
  ///
  /// 不能挂在"刚听到有声"那一瞬间上：Silero 一判到有声就 `speaking=true`，
  /// 而那个标志会一直扛到整段收尾（要静满 `vadMinSilenceMs` 才落回），
  /// **跟这段有多长无关**。所以咳嗽、清嗓子、叹一口气都是一声就把 AI
  /// 打断了 —— 用户没说话，它却让了位。
  ///
  /// 这里数的是**概率够格的帧**累计了多久：一声就没了，累计不够，不打断；
  /// 中间一帧掉下阈值就重新数，所以只认连续的。
  void _trackSpeechRun(SegmenterStats stats, int frameBytes) {
    // "他在说"这件事还是以断句器为准（它含收尾那段静音），
    // 排队播放要按它来决定让不让位。
    _userSpeaking = stats.speaking;

    if (!stats.speaking || stats.probability < _config.vadThreshold) {
      _speechRunMs = 0;
      _bargeInFired = false;
      return;
    }

    final rate = _format?.sampleRate ?? 16000;
    _speechRunMs += frameBytes * 500 ~/ rate;

    if (!_config.bargeIn || _bargeInFired) return;
    if (_speechRunMs < bargeInMinSpeechMs) return;

    _bargeInFired = true;
    unawaited(_bargeInIfAudible());
  }

  /// 真的还有声音没放完，才打断。
  ///
  /// [_speaking] 为真时不用再问原生（推送循环还在跑，必然有声音）。
  /// 否则现问一次缓冲 —— 不能等 `_backlogFrames`，它每 500ms 才刷一次，
  /// 而"推送循环结束、声音还在响"正是打断最该生效的那一段。
  Future<void> _bargeInIfAudible() async {
    if (_speaking) {
      await _interruptAndReport();
      return;
    }
    final backlog = await _engine.playbackBacklogFrames();
    if (backlog <= 0) return;
    await _interruptAndReport();
  }

  /// 新到的回复该不该先按下不播。
  ///
  /// 只在「打断」开着、而且用户**那一句还没说完**时按。理由：打断是在
  /// "开口"那一刻触发的，你一直在说就不会有第二次开口事件，这条播下去
  /// 也没人拦得住 —— 只会盖在人家说话上面，用户还听不清。
  /// 关着打断时保持老样子：收到就播。
  bool _shouldDeferForSpeaking() => _config.bargeIn && _userSpeaking;

  /// 双讲门：AI 在出声、而麦克风电平没明显高过播放电平时，把这一帧当回声。
  ///
  /// Silero 比能量阈值**强得多**，AEC 的残留它会当成"有人在说话" ——
  /// 于是切出一句送上去，又触发一轮回复，变成自激循环。旧 EnergyVad 里
  /// 有同样的参数，但生产路径从没传过，等于没接线。这次是真的接上了。
  ///
  /// 它**只在打断开关关着**时起作用。开着的时候你一开口就该把它打断，
  /// 而不是把你说的那句吞掉 —— 那时候门必须让开，哪怕 AEC 不干净、
  /// 它自己的声音也有可能把人声吵醒（代价就是可能自己打断自己）。
  ///
  /// 注意喂的是**数字静音**而不是直接跳过：模型状态和 512 采样的推进节奏
  /// 必须连续，否则残留一消失就会来一次"语音起止"，切出来的段全是碎的。
  bool _shouldMuteMic() {
    if (_config.bargeIn) return false;
    // 用 getter 而不是 `_speaking`：缓冲区里还有声音时同样要把麦克风当回声。
    if (!speaking) return false;
    final levels = levelsNotifier.value;
    // 播放电平还没起来（例如刚起播、数据还没推下去）时不判，免得把开头吞掉。
    if (levels.playbackDb <= -100) return false;
    return levels.micDb <= levels.playbackDb + doubleTalkMarginDb;
  }

  Uint8List _silence(int length) {
    final buf = _silenceBuf;
    if (buf == null || buf.length != length) {
      _silenceBuf = Uint8List(length);
    }
    return _silenceBuf!;
  }

  void _onUtterance(SpeechSegment segment) {
    debugPrint('SPK keep ${segment.durationSeconds.toStringAsFixed(2)}s '
        'cos=${segment.speakerCos.toStringAsFixed(3)} '
        'pvad=${segment.pvadScore.toStringAsFixed(3)} '
        'ratio=${segment.pvadTargetRatio.toStringAsFixed(2)}');
    _userSpeaking = false;
    // 这轮说完了，下一轮从头数起 —— 不然上一句攒的时长会算到下一句头上，
    // 让一句很轻的"嗯"也够格打断。
    _speechRunMs = 0;
    _bargeInFired = false;
    notifyListeners();

    // 闭麦期间切出来的段直接丢。喂的是静音，正常切不出来；但模型里可能还挂着
    // 闭麦前那半句，会在切到静音的瞬间收尾 —— 宁可丢掉，也不要在这时候
    // 冒一个上传出去（"闭麦就一个字节都不上去"必须是硬保证，不能靠推理）。
    if (_micMuted) {
      _append('闭麦中，丢掉一段 ${segment.durationSeconds.toStringAsFixed(1)}s');
      return;
    }

    final how = segment.forcedCut ? '说太久强制切' : '停顿切';
    final warn = segment.truncated ? '，⚠️ 开头已被缓冲挤掉' : '';
    _append('切出一句 ${segment.durationSeconds.toStringAsFixed(1)}s'
        '（${segment.sampleRate}Hz / $how / prob=${segment.probability.toStringAsFixed(2)}）'
        '$warn，排队上传');

    _speakQueue?.add(
      QueuedUtterance(
        pcm16le: segment.pcm16le,
        // **用 segment 自己声明的采样率，不是采集率。**
        // 采集率是 48000 的设备上写错这个，就会发出 48k 的 Ogg，
        // 而规范只收 16kHz —— 服务端拒收，而且报错离现场很远，很难查。
        sampleRate: segment.sampleRate,
        durationSeconds: segment.durationSeconds,
      ),
    );
  }

  Future<void> _sendUtterance(QueuedUtterance utterance) async {
    if (!_active) return;

    // 上行只可能属于聚焦的那个档案 —— 采集、断句、上传这条链路整个挂在
    // controller 上，未聚焦的档案里根本不存在这些东西。
    final runtime = focused;
    if (runtime == null) return;
    final brain = runtime.profile.brain;

    try {
      // 规范只收 Ogg Opus，所以没有回落分支 ——
      // 编码器不可用就明确报错，不发一个服务端一定拒的格式。
      final opus = await _engine.encodeOpus(
        utterance.pcm16le,
        sampleRate: utterance.sampleRate,
      );
      if (!_active) return;

      if (opus == null) {
        _opusUpstream = false;
        _append('⚠️ 本机没有可用的 Opus 编码器，这段语音发不出去');
        runtime.setError('本机缺少 Opus 编码器');
        notifyListeners();
        return;
      }
      _opusUpstream = true;

      // 这两笔账读的是**当前档案**的。切换档案不会把它们带走，
      // 所以在 A 里攒下的"漏听"不会报给 B。
      final heard = runtime.pendingHeardMs;
      final unheard = runtime.pendingUnheardText;
      _append('上传 ${_kb(opus.length)} → /human-to-brain'
          '${heard == null ? "" : "（附：上一段只听到 ${(heard / 1000).toStringAsFixed(1)}s）"}'
          '${unheard == null ? "" : "（没听到：$unheard）"}');

      final result = await runtime.brain.humanToBrain(
        baseUrl: brain.baseUrl,
        brainId: brain.brainId,
        token: brain.token,
        oggBytes: opus,
        heardMs: heard,
        unheardText: unheard,
      );

      if (!_active) return;

      // 请求落地了，这条就不用再挂着。失败时走不到这里 —— 留着给下一次，
      // "你漏了一段"迟到也比丢了好。
      runtime.pendingHeardMs = null;
      runtime.pendingUnheardText = null;

      final text = result.text.trim();
      if (text.isEmpty) {
        _append('/human-to-brain 返回空文本');
        return;
      }
      runtime.setError(null);
      runtime.authFailed = false;
      await runtime.record(MessageRole.user, text);
    } on BrainException catch (e) {
      // 会话已经结束的话，这个异常多半是我们自己 abort() 断出来的，
      // 不是真的网络故障，别报出来吓人。
      if (!_active) return;
      _append(e.message);
      if (e.kind == BrainErrorKind.auth) {
        runtime.authFailed = true;
      }
      runtime.setError(e.message);
    } catch (e) {
      if (!_active) return;
      _append('/human-to-brain 失败：$e');
      runtime.setError('$e');
    }
  }

  // ---------------------------------------------------------------- 播放队列（另一条线）

  /// 把一条拿到的回复塞进播放队列，并叫醒播放循环。**不等它播完。**
  void _enqueueReply(String text, Uint8List audio, List<BrainSpan> spans) {
    // 轮询比播放快得多时的兜底，免得对面一口气灌进来把内存吃光。
    // 丢掉的如实记成"没听到" —— 它确实没进用户耳朵。
    if (_replyQueue.length >= replyQueueLimit) {
      final dropped = _replyQueue.removeAt(0);
      _appendUnheard(dropped.text);
      _append('播放队列满了，丢掉最早的一条（算没听到）');
    }

    _replyQueue.add(_PendingReply(text: text, audio: audio, spans: spans));

    final signal = _queueSignal;
    _queueSignal = null;
    signal?.complete();
    notifyListeners();
  }

  /// 等队列里来东西。播放循环空转时挂在这上面。
  Future<void> _waitForReply() {
    final existing = _queueSignal;
    if (existing != null) return existing.future;
    final completer = Completer<void>();
    _queueSignal = completer;
    return completer.future;
  }

  /// 播放循环：从队头取一条播一条。和轮询那条完全独立。
  Future<void> _playbackLoop() async {
    while (_active) {
      if (_replyQueue.isEmpty) {
        await _waitForReply();
        continue;
      }

      // 播放测试音时不碰这条线，免得两处一起往同一个 AudioTrack 里推。
      if (_testToneOn) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        continue;
      }

      final reply = _replyQueue.removeAt(0);

      // 它已经不在队列里了，先把"上一条"的账清掉：这中间的每一次 await
      // 都可能是打断点，留着上一条的文字会被算到这一条头上。
      // [_playReplyAudio] 真跑起来时会重新填上。
      _replyText = '';
      _replySpans = const <BrainSpan>[];
      _replyTotalMs = 0;

      // 用户那一句还没说完。打断是在"开口"那一刻触发的，你一直在说就不会有
      // 第二次开口事件 —— 这条播下去也没人拦得住，只会盖在人家说话上面。
      // 整条记成"没听到"，跟下一句一起告诉 brain。
      if (_shouldDeferForSpeaking()) {
        _appendUnheard(reply.text);
        _append('你还在说话，这条先不播（整条算没听到）');
        continue;
      }

      try {
        await _playReplyAudio(reply.audio, reply.spans, reply.text);
      } catch (e) {
        // _playReplyAudio 自己会记，这里只是不让整个循环因为一条坏回复死掉。
        _append('播放失败：$e');
      }
    }
  }

  Future<void> _playReplyAudio(
    Uint8List encoded,
    List<BrainSpan> spans,
    String text,
  ) async {
    final format = _format;
    if (format == null) return;

    // 记下这条的"账"：被打断时靠它把"播到第几毫秒"翻成"哪几句没听到"。
    // spans 可能为空，那还有 _replyText + _replyTotalMs 这一层兜底。
    _replySpans = spans;
    _replyText = text;

    // 基线在**解码之前**就取。放到解码后面的话，解码那几十到几百毫秒里
    // 被打断，算出来的"已听到"还是上一条的时长，这一整条就会被误判成
    // "已经听完了" —— 一个字都没播，却报了个空。
    _replyHeadBaseMs = await _engine.playbackHeadMs();

    final epoch = _playbackEpoch;

    try {
      // 解码在原生做 —— Dart 没有可用的 Opus 解码器
      final decoded = await _engine.decodeAudio(encoded);
      if (!_active || epoch != _playbackEpoch) return;

      // 注意：不能假设解码出来的采样率等于声明的采样率。
      // Opus 内部固定跑 48kHz，MediaCodec 通常直接给 48000 ——
      // 写死 24k 会变速，而且很难查。
      final pcm = toPlaybackPcm(
        decoded.pcm16le,
        sourceRate: decoded.sampleRate,
        sourceChannels: decoded.channels,
        targetRate: format.sampleRate,
      );
      if (pcm.isEmpty) {
        _append('解码后没有音频数据');
        return;
      }

      // 这条回复的音频总长。brain 没给 spans 时，按比例估位置就靠它。
      _replyTotalMs = (pcm.length ~/ 2) * 1000 ~/ format.sampleRate;

      _append(
        '播放 ${(pcm.length / 2 / format.sampleRate).toStringAsFixed(1)}s'
        '（解码出 ${decoded.sampleRate}Hz/${decoded.channels}ch'
        '${decoded.sampleRate != format.sampleRate ? " → ${format.sampleRate}Hz" : ""}）',
      );

      _speaking = true;
      notifyListeners();

      final bytesPerChunk = format.sampleRate * 2;
      for (var offset = 0; offset < pcm.length; offset += bytesPerChunk) {
        if (epoch != _playbackEpoch || !_active) break;
        final end = (offset + bytesPerChunk).clamp(0, pcm.length);
        await _engine.pushPlayback(
          Uint8List.sublistView(pcm, offset, end),
          epoch: epoch,
        );
      }
    } catch (e) {
      _append('播放失败：$e');
    } finally {
      if (epoch == _playbackEpoch) {
        _speaking = false;
        notifyListeners();
      }
    }
  }

  // ---------------------------------------------------------------- 清空播放队列

  /// 手动清空 AI 语音。只清音频，会话继续。
  ///
  /// 触发方式：通知栏「停止说话」按钮（覆盖后台/锁屏），
  /// 或前台的音量减键（后台收不到，由通知按钮补上）。
  Future<void> clearPlayback() async {
    if (!_active) return;
    if (!_speaking &&
        _replyQueue.isEmpty &&
        await _engine.playbackBacklogFrames() == 0) {
      _append('当前没有在播放');
      return;
    }
    final heard = await _heardMs();
    final (discarded, queued) = await _interruptPlayback();
    _recordHeard(heard, discarded, queued, '已清空 AI 语音');
  }

  /// 用户开口打断。和手动清空是同一件事，只是触发源不同。
  Future<void> _interruptAndReport() async {
    final heard = await _heardMs();
    final (discarded, queued) = await _interruptPlayback();
    _recordHeard(heard, discarded, queued, '打断');
  }

  /// 记下"上一段只听到这么多"，等下一次上传时带给 brain。
  ///
  /// 挂到下一次请求而不是当场单独发一条：协议里没有汇报端点，
  /// 而且它天然属于"下一句话的上下文"。
  void _recordHeard(
    int heardMs,
    int discarded,
    String queuedText,
    String why, {
    /// 这笔账记在谁头上。**默认是此刻聚焦的那个**，但切换/关档案那条路上
    /// 有 await，中途焦点可能已经变了 —— 那就得显式传"声音本来属于谁"，
    /// 不然旧档案没听完的话会被记到新档案头上。
    ProfileRuntime? target,
  }) {
    final to = target ?? focused;
    to?.pendingHeardMs = heardMs;

    // 就是用户给的那个式子：
    //   被打断的那条没听完的尾巴 ++ 队列里还没轮到播的整条正文
    _appendUnheard(_unheardFrom(heardMs), to);
    _appendUnheard(queuedText, to);

    // 这条的账已经算过了，清掉 —— 不然紧接着再来一次打断（比如通知栏
    // 又按一下）会把同一段文字重复算一遍。
    _replyText = '';
    _replySpans = const <BrainSpan>[];
    _replyTotalMs = 0;

    _append('$why（丢弃 $discarded 帧，已听到 ${(heardMs / 1000).toStringAsFixed(1)}s）'
        '—— 下次上传时告诉 brain');
  }

  /// 往"没听到的文字"里追加一段。
  ///
  /// 这个量是**累加**的：
  ///
  /// ```
  /// unheard_text = 正在播的那条没听完的尾巴
  ///              ++ 队列里还没轮到播的整条正文
  /// ```
  ///
  /// 累加而不是覆盖：一次打断只处理到当时的队列，之后队列还会再进东西
  /// （取的那条线一直在跑），那些也得算上，直到下一次上传成功才清。
  ///
  /// 账记在**聚焦档案**头上。切档案时先结账再切，所以这些字会正确地
  /// 报给说这些话的那个 brain，不会串到别的档案去。
  void _appendUnheard(String? chunk, [ProfileRuntime? target]) {
    (target ?? focused)?.appendUnheard(chunk);
  }

  /// 焦点即将离开当前这个档案之前必须做的事：把没听完的账结掉、把声音停掉。
  ///
  /// **改焦点不止"滑动切换"一条路**：关掉正在聚焦的档案、把它删掉，
  /// `normalized()` 也会把焦点挪到别人身上。不在这一个地方收口的话，
  /// 那条路上声音会接着响（队列里还压着它的回复），而"没听完的那几句"
  /// 会被记到**新**档案头上 —— 下次跟新档案说话，旧档案的漏听文本就报给它了。
  Future<void> _settleBeforeLeavingFocus() async {
    // 结账对象**进函数时就钉死**：下面有 await，中途焦点可能被改掉。
    final leaving = focused;
    if (leaving == null) return;

    // 还没发出去的那几句**直接丢掉**（用户定的规矩）。
    //
    // 留着的话，轮到它们发的时候会按"当时聚焦的档案"决定发给谁 —— 而你
    // 已经切走了，于是新档案的历史里凭空多出一条它根本没听到的"你说的话"，
    // 旧档案的 brain 则永远不知道你说过这句。
    //
    // 丢掉的意思是：切走 = 之前还没发出去的不再发了。已经在发的那一句拦不住
    // （它的目标在开始发的时候就定了，那时候还是对的）。本地的用户消息是
    // `/human-to-brain` 成功之后才记的，所以丢掉也不会在历史里留半条。
    final stranded = _speakQueue?.pendingCount ?? 0;
    if (stranded > 0) {
      _speakQueue?.clear();
      _append('切档案：丢掉还没上传的 $stranded 句');
    }

    if (!_active) {
      // 没在会话里，播放循环本来就没跑。但还是要抬 epoch —— 万一有在途的
      // 解码/推送，它会看到 epoch 变了而自己退出去。
      _playbackEpoch++;
      _replyQueue.clear();
      return;
    }

    final wasAudible = speaking;
    final heard = wasAudible ? await _heardMs() : 0;
    final (discarded, queued) = await _interruptPlayback();
    if (!wasAudible) return;

    _recordHeard(heard, discarded, queued, '切换档案，停掉正在播的语音',
        target: leaving);
    // 用户切回来会看到文字却想不起当时没听完，留一行痕。
    // 只在真的打断了声音时才留，光切来切去不写。
    if (_config.focusedProfileId == leaving.id) {
      _addMessage(MessageRole.note, '切走的时候这条没播完');
    }
  }

  /// 把"播到第几毫秒"翻成"哪几个字没被听到"。
  ///
  /// 两层：brain 给了按句的时间账就用它（精确）；没给就按比例估。
  /// **一句只要没被完整听完，整句都算没听到** —— 半句话比整句更容易
  /// 让人误以为听全了。
  String? _unheardFrom(int heardMs) {
    if (_replyText.isEmpty) return null;

    if (_replySpans.isNotEmpty) {
      final buf = StringBuffer();
      var acc = 0;
      for (final span in _replySpans) {
        acc += span.ms;
        if (acc > heardMs) buf.write(span.text);
      }
      final unheard = buf.toString().trim();
      return unheard.isEmpty ? null : unheard;
    }

    return _unheardByEstimate(heardMs);
  }

  /// 按比例估：假设"文字长短和音频时长成正比"。
  ///
  /// 长回复里这个假设站得住（语速大体均匀），但标点停顿、数字、英文词、
  /// 尾巴上的静音都会把它带偏。所以只当 spring back：估出来的位置**往后
  /// 找最近的句子边界再切**，不把句子从中间劈开。宁可多报一句，
  /// 也不要让用户漏听半句却以为听全了。
  String? _unheardByEstimate(int heardMs) {
    if (_replyTotalMs <= 0) return null;

    final chars = _replyText.length;
    final guess = (chars * heardMs / _replyTotalMs).round();

    final cut = _boundaryAtOrAfter(guess);
    if (cut >= chars) return null;

    final unheard = _replyText.substring(cut).trim();
    return unheard.isEmpty ? null : unheard;
  }

  /// 从 [from] 起的第一处断句点（返回它**后面**一位）。找不到就原样返回。
  int _boundaryAtOrAfter(int from) {
    for (var i = from.clamp(0, _replyText.length);
        i < _replyText.length;
        i++) {
      if (_sentenceBreaks.contains(_replyText[i])) return i + 1;
    }
    return from;
  }

  /// 这条回复**已经播出去**多少毫秒。
  ///
  /// 问原生要播放头，再减掉开播时的基线。不能拿"推下去了多少"代替：
  /// 推下去的还堆在缓冲区里，那部分用户根本还没听到。
  Future<int> _heardMs() async {
    try {
      final heard = await _engine.playbackHeadMs() - _replyHeadBaseMs;
      return heard < 0 ? 0 : heard;
    } catch (_) {
      // 拿不到就当 0（"一句都没听到"）。宁可少报，也不要编一个假位置给 brain。
      return 0;
    }
  }

  /// 作废当前正在播放的音频。
  ///
  /// **取的那条线不动** —— 协议里没有取消端点，音频字节早就到了，
  /// 而且接着问下一条正是我们要的。这里只把**还没播出去的**丢掉：
  /// 正在播的那条靠抬 epoch 作废，队列里还没轮到的那几条直接清掉，
  /// 并把它们的正文一并交出去（它们同样没进用户耳朵）。
  ///
  /// 返回 (丢弃的帧数, 队列里被清掉的那些正文)。
  Future<(int, String)> _interruptPlayback() async {
    _playbackEpoch++;
    _speaking = false;

    final queued = StringBuffer();
    for (final pending in _replyQueue) {
      queued.write(pending.text);
    }
    if (_replyQueue.isNotEmpty) {
      _append('清掉队列里 ${_replyQueue.length} 条还没播的（整条算没听到）');
      _replyQueue.clear();
    }

    final discarded = await _engine.flushPlayback(newEpoch: _playbackEpoch);
    notifyListeners();
    return (discarded, queued.toString());
  }

  // ---------------------------------------------------------------- 引擎事件

  void _onLevels(AudioLevels levels) {
    levelsNotifier.value = levels;
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case EndRequested():
        _append('通知栏请求结束');
        unawaited(stop());

      case ClearPlaybackRequested():
        unawaited(clearPlayback());

      case MicSilentlyDead(:final reason):
        // 文档点名的那个坑：不报错、只是没声音。既然已经确定死了，
        // 就不装作还在工作。
        _append('⚠️ 麦克风静默失效：$reason');
        unawaited(stop());

      case EngineFailure(:final reason):
        _append('⚠️ 引擎故障：$reason');

      case ManualAecUnavailable():
        _append('⚠️ 本机不支持手动 AEC（不影响 voiceCommunication 路径）');

      case InterruptionBegan(:final transient, :final canDuck):
        if (!transient) {
          _append('音频焦点被永久抢占，结束会话');
          unawaited(stop());
        } else if (canDuck) {
          _append('音频焦点被短暂抢占（可降音量继续）');
        } else {
          _append('音频焦点被短暂抢占');
        }

      case InterruptionEnded(:final shouldResume):
        _append('音频焦点已恢复（resume=$shouldResume）');
    }
  }

  // ---------------------------------------------------------------- 调试配置

  Future<void> updateDebugProfile(DebugAudioProfile profile) async {
    _debugProfile = profile;
    notifyListeners();

    if (!_active) return;
    _append('切换音频配置：${_describeProfile(profile)}');
    await _restartAudio();
  }

  Future<void> _restartAudio() async {
    if (_speaking) await _interruptPlayback();

    await _micSub?.cancel();
    _micSub = null;

    await _engine.stopAudio();
    await _engine.applyDebugProfile(_debugProfile);

    try {
      final format = await _engine.startAudio();
      _format = format;
      // 采样率可能变了（换了采集源/性能模式），segmenter 必须跟着重建。
      if (!await _openSegmenter(format.sampleRate)) {
        notifyListeners();
        return;
      }
      _micSub = _engine.micPcm.listen(_onMicFrame);
      _append('音频链路已重启：$format');
    } catch (e) {
      _append('重启音频失败：$e');
    }
    notifyListeners();
  }

  String _describeProfile(DebugAudioProfile p) =>
      '${p.captureSource.name} / ${p.playbackUsage.name} / ${p.performanceMode.name}'
      ' / aec=${p.manualAec ? "on" : "off"} / spk=${p.speakerphone ? "on" : "off"}';

  /// 调试用：把一段测试音当成"你说的一句话"走完整条上行链路。
  ///
  /// 存在的意义是**不需要麦克风就能验证上行** —— 编码、multipart、
  /// 鉴权、文本回流。模拟器上没法说话，真机调试时也用得上。
  Future<void> sendTestUtterance() async {
    if (!_active) {
      _append('先点「开始对话」');
      return;
    }
    final format = _format;
    if (format == null) return;

    const seconds = 1.5;
    final frames = (format.sampleRate * seconds).round();
    final pcm = _testTone.render(
      sampleRate: format.sampleRate,
      startFrame: 0,
      frames: frames,
      totalFrames: frames,
    );

    _append('发送测试语音 ${seconds}s，走完整条上行链路');
    _speakQueue?.add(
      QueuedUtterance(
        pcm16le: pcm,
        sampleRate: format.sampleRate,
        durationSeconds: seconds,
      ),
    );
  }

  // ---------------------------------------------------------------- AEC 自测

  static const _testTone = TestToneGenerator();

  bool _testToneOn = false;
  bool get testToneOn => _testToneOn;

  /// 循环播放测试音，**不依赖 brain**。
  ///
  /// 这是验证 AEC 的核心手段：播测试音时看麦克风电平条，
  /// 接近静默说明 AEC 生效。brain 没起也能用。
  Future<void> toggleTestTone() async {
    if (!_active) {
      _append('先点「开始对话」');
      return;
    }

    if (_testToneOn) {
      _testToneOn = false;
      await _interruptPlayback();
      _append('停止测试音');
      notifyListeners();
      return;
    }

    _testToneOn = true;
    _append('播放测试音（AEC 自测）—— 看麦克风电平条是否接近静默');
    notifyListeners();
    unawaited(_playTestToneLoop());
  }

  Future<void> _playTestToneLoop() async {
    final format = _format;
    if (format == null) return;

    final epoch = _playbackEpoch;
    _speaking = true;
    _replyHeadBaseMs = await _engine.playbackHeadMs();
    // 测试音不是 brain 说的，没有"哪句话没听到"可言
    _replySpans = const <BrainSpan>[];
    _replyText = '';
    _replyTotalMs = 0;
    notifyListeners();

    const burstMs = 2000;
    try {
      while (_testToneOn && _active && epoch == _playbackEpoch) {
        final frames = format.sampleRate * burstMs ~/ 1000;
        await _engine.pushPlayback(
          _testTone.render(
            sampleRate: format.sampleRate,
            startFrame: 0,
            frames: frames,
            totalFrames: frames,
          ),
          epoch: epoch,
        );
        await Future<void>.delayed(const Duration(milliseconds: burstMs));
      }
    } finally {
      _testToneOn = false;
      // 必须无条件通知：清空队列也会走到这里（epoch 已变），
      // 那时如果不通知，按钮会一直停在"停止测试音"上。
      if (epoch == _playbackEpoch) _speaking = false;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- 收尾

  Future<void> _teardown() async {
    _active = false;

    // 立刻掐掉所有在途的请求。
    // 尤其是那些长轮询 —— 服务端的 handler 接了 AbortSignal，
    // 我们一断开它就会取消自己的工作；不断的话它会一直挂到超时。
    // 每个档案一个客户端，所以要逐个停（stopPolling 内部会 abort）。
    for (final runtime in _runtimes.values) {
      await runtime.stopPolling();
    }

    _statsTimer?.cancel();
    _statsTimer = null;

    // 叫醒播放循环让它看到 _active 已经翻了，再把队列放掉。
    // 不放的话它挂在 _waitForReply() 上，这个 Future 永远不回来。
    _replyQueue.clear();
    final signal = _queueSignal;
    _queueSignal = null;
    signal?.complete();
    await _playbackTask;
    _playbackTask = null;

    await _micSub?.cancel();
    _micSub = null;
    await _levelSub?.cancel();
    _levelSub = null;
    await _eventSub?.cancel();
    _eventSub = null;

    _speakQueue?.dispose();
    _speakQueue = null;
    _segmenter?.dispose();
    _segmenter = null;
    _silenceBuf = null;

    try {
      await _engine.stopAudio();
    } catch (_) {}
    try {
      await _engine.stopService();
    } catch (_) {}

    // 会话结束时闭麦也算结束：先把痕留下，免得用户看着"闭麦中"
    // 然后什么都没有。消息流本身不清 —— 它就留在这儿，下次打开还在。
    if (_micMuted) {
      _micMuted = false;
      _flushMuteTrace();
    }
    _mutedMs = 0;
    _replySpans = const <BrainSpan>[];
    _replyText = '';
    _replyTotalMs = 0;

    // 「没听到」那两笔账**故意不清**：它是"下一句要带给 brain 的上下文"，
    // 会话结束不等于这件事没发生过。下次接着说话时照样会带过去。
    // 错误态也不清：它是档案的属性，不是这次会话的。

    _format = null;
    _userSpeaking = false;
    _speechRunMs = 0;
    _bargeInFired = false;
    _speaking = false;
    _testToneOn = false;
    _droppedMicFrames = 0;
    _backlogFrames = 0;
    levelsNotifier.value = const AudioLevels(micDb: -120, playbackDb: -120);
  }

  Future<void> _refreshStats() async {
    try {
      _droppedMicFrames = await _engine.droppedMicFrames();
      _backlogFrames = await _engine.playbackBacklogFrames();
      notifyListeners();
    } catch (_) {
      // 会话正在收尾时查询会失败，忽略
    }
  }

  /// 往**聚焦档案**的消息流里写一条。
  ///
  /// 落盘是异步的：先把消息写进盘、由 store 发号，拿到带 seq 的那条再进内存。
  /// 调用点一律不 await —— 界面晚几毫秒看到消息，比内存里的 seq 和盘上
  /// 对不上强得多（对不上会让往上翻历史漏条重条）。
  void _addMessage(MessageRole role, String text) {
    final runtime = focused;
    if (runtime == null) return;
    unawaited(runtime.record(role, text));
  }

  void _append(String message) {
    _log.insert(0, LogEntry(message));
    while (_log.length > logLimit) {
      _log.removeLast();
    }
    // 用带守卫的通知：dispose 之后平台侧可能还有回调在飞，
    // 打在已 dispose 的 ChangeNotifier 上是 debug 断言失败。
    _safeNotify();
  }

  static String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(1)}KB';

  /// 放掉三条音频订阅。
  ///
  /// dispose 是同步的，而 cancel 返回 Future —— **不等**。取消这件事本身
  /// 是立刻生效的，Future 等的是收尾。不放的话，平台侧还在推帧，回调会
  /// 打在已经 dispose 的 `levelsNotifier` 上。
  void _cancelAudioSubscriptions() {
    final mic = _micSub;
    final level = _levelSub;
    final event = _eventSub;
    _micSub = null;
    _levelSub = null;
    _eventSub = null;
    if (mic != null) unawaited(mic.cancel());
    if (level != null) unawaited(level.cancel());
    if (event != null) unawaited(event.cancel());
  }

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    _statsTimer?.cancel();
    // 别让播放循环挂在没人叫醒的 Future 上
    _queueSignal?.complete();
    _queueSignal = null;
    _speakQueue?.dispose();
    _segmenter?.dispose();
    _cancelAudioSubscriptions();
    levelsNotifier.dispose();
    for (final runtime in _runtimes.values) {
      unawaited(runtime.dispose());
    }
    _runtimes.clear();
    super.dispose();
  }
}
