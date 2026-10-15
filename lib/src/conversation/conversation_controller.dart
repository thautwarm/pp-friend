import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/pcm_utils.dart';
import '../audio/segmenter.dart';
import '../audio/silero_segmenter.dart';
import '../audio/test_tone.dart';
import '../brain/brain_client.dart';
import '../config/assistant_config.dart';
import '../config/config_store.dart';
import '../voice/voice_engine.dart';
import 'message.dart';
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
    SegmenterFactory? segmenterFactory,
  })  : _engine = engine ?? VoiceEngine.instance,
        _store = store ?? ConfigStore(),
        _brain = brain ?? BrainClient(),
        _segmenterFactory = segmenterFactory ?? _defaultSegmenterFactory;

  static Future<Segmenter> _defaultSegmenterFactory({
    required int sampleRate,
    required AssistantConfig config,
  }) =>
      SileroSegmenter.open(inputSampleRate: sampleRate, config: config);

  final VoiceEngine _engine;
  final ConfigStore _store;
  final BrainClient _brain;
  final SegmenterFactory _segmenterFactory;

  static const int messageLimit = 300;
  static const int logLimit = 120;

  /// 双讲判据的余量：麦克风电平要比播放电平高这么多，才算"真的是你在说"。
  static const double doubleTalkMarginDb = 6;

  /// 网络失败的重试退避上限。
  static const int maxBackoffMs = 15000;

  // ---------------------------------------------------------------- 配置

  AssistantConfig _config = const AssistantConfig();
  AssistantConfig get config => _config;

  DebugAudioProfile _debugProfile = const DebugAudioProfile();
  DebugAudioProfile get debugProfile => _debugProfile;

  Future<void> loadConfig() async {
    _config = await _store.load();
    notifyListeners();
  }

  Future<void> updateConfig(AssistantConfig config) async {
    _config = config;
    notifyListeners();
    await _store.save(config);
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

  bool _polling = false;
  bool get polling => _polling;

  /// 上行是否在用 Opus。启动时运行时探测一次。
  bool _opusUpstream = false;
  bool get opusUpstream => _opusUpstream;

  final ValueNotifier<AudioLevels> levelsNotifier =
      ValueNotifier(const AudioLevels(micDb: -120, playbackDb: -120));

  final List<ConversationMessage> _messages = <ConversationMessage>[];
  List<ConversationMessage> get messages => List.unmodifiable(_messages);

  final List<LogEntry> _log = <LogEntry>[];
  List<LogEntry> get log => List.unmodifiable(_log);

  int _droppedMicFrames = 0;
  int get droppedMicFrames => _droppedMicFrames;

  int _backlogFrames = 0;
  int get backlogFrames => _backlogFrames;

  int get queuedUtterances => _speakQueue?.pendingCount ?? 0;
  int get droppedUtterances => _speakQueue?.dropped ?? 0;

  /// 最近一次 brain 失败的原因。成功一次就清掉。
  ///
  /// 网络抖动本来就不该往外抛（协议层没有错误响应），但让用户完全看不见
  /// 也不对 —— brain 连不上时主界面停在"正在听你说"是骗人的。
  /// 鉴权失败则必须显式提示，那属于配置错误。
  String? _brainError;
  String? get brainError => _brainError;

  bool get authFailed => _authFailed;
  bool _authFailed = false;

  void _setBrainError(String? message) {
    if (_brainError == message) return;
    _brainError = message;
    notifyListeners();
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

  /// 上一段 AI 语音里，用户**实际听到了多少毫秒**。
  ///
  /// 挂在下一句 /human-to-brain 上带过去（协议里没有单独的汇报端点）。
  /// 上传成功才清掉：失败就留着，迟到也比丢了强。
  int? _pendingHeardMs;

  /// "没听到的那部分文字"，攒到下一次上传才发出去。
  ///
  /// **是累加的，不是覆盖的。** 一次打断只算出"当前这条回复"没听完的尾巴，
  /// 但被打断之后 brain 往往还会再发一条，那条也可能整个没被听到 ——
  /// 只留最后一次，前面那些就凭空消失了。攒到上传成功才清。
  String? _pendingUnheardText;

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
      _messages.clear();
      _authFailed = false;
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

      // 循环 B 独立跑，不阻塞 start()
      unawaited(_pollBrainToHumanLoop());
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
        _setBrainError('本机缺少 Opus 编码器');
        notifyListeners();
        return;
      }
      _opusUpstream = true;

      final heard = _pendingHeardMs;
      final unheard = _pendingUnheardText;
      _append('上传 ${_kb(opus.length)} → /human-to-brain'
          '${heard == null ? "" : "（附：上一段只听到 ${(heard / 1000).toStringAsFixed(1)}s）"}'
          '${unheard == null ? "" : "（没听到：$unheard）"}');

      final result = await _brain.humanToBrain(
        baseUrl: _config.brain.baseUrl,
        brainId: _config.brain.brainId,
        token: _config.brain.token,
        oggBytes: opus,
        heardMs: heard,
        unheardText: unheard,
      );

      if (!_active) return;

      // 请求落地了，这条就不用再挂着。失败时走不到这里 —— 留着给下一次，
      // "你漏了一段"迟到也比丢了好。
      _pendingHeardMs = null;
      _pendingUnheardText = null;

      final text = result.text.trim();
      if (text.isEmpty) {
        _append('/human-to-brain 返回空文本');
        return;
      }
      _setBrainError(null);
      _authFailed = false;
      _addMessage(MessageRole.user, text);
    } on BrainException catch (e) {
      // 会话已经结束的话，这个异常多半是我们自己 abort() 断出来的，
      // 不是真的网络故障，别报出来吓人。
      if (!_active) return;
      _append(e.message);
      if (e.kind == BrainErrorKind.auth) {
        _authFailed = true;
      }
      _setBrainError(e.message);
    } catch (e) {
      if (!_active) return;
      _append('/human-to-brain 失败：$e');
      _setBrainError('$e');
    }
  }

  // ---------------------------------------------------------------- 循环 B：轮询 /brain-to-human

  Future<void> _pollBrainToHumanLoop() async {
    _polling = true;
    notifyListeners();

    var backoffMs = 500;

    loop:
    while (_active) {
      try {
        final response = await _brain.brainToHuman(
          baseUrl: _config.brain.baseUrl,
          brainId: _config.brain.brainId,
          token: _config.brain.token,
        );

        if (!_active) break;

        backoffMs = 500;
        _setBrainError(null);

        switch (response) {
          case BrainEmpty():
            // 立刻再发一次，不停不等
            continue loop;

          case BrainReply(:final text, :final audio, :final spans):
            // 文本永远进消息流，无论语音后面会不会被清掉
            if (text.trim().isNotEmpty) {
              _addMessage(MessageRole.assistant, text);
            }
            if (audio.isEmpty) {
              _append('/brain-to-human 只有文本，没有音频');
            } else {
              // **只管塞进队列，不等它播完** —— 塞完立刻回去问下一条。
              // 播放是另一条线的事。
              _enqueueReply(text, audio, spans);
            }
        }
      } on BrainException catch (e) {
        if (!_active) break;

        _setBrainError(e.message);
        _append(e.message);

        // 401 是配置错误，重试只会把它变成持续请求 —— 停下并提示
        if (e.kind == BrainErrorKind.auth) {
          _authFailed = true;
          _append('⚠️ 鉴权失败，已停止轮询。检查配置里的 token。');
          break;
        }

        // 网络问题自己退避重试，不往外抛
        _append('${backoffMs}ms 后重试');
        await Future<void>.delayed(Duration(milliseconds: backoffMs));
        backoffMs = (backoffMs * 2).clamp(500, maxBackoffMs);
      } catch (e) {
        if (!_active) break;
        _append('/brain-to-human 异常：$e');
        await Future<void>.delayed(Duration(milliseconds: backoffMs));
        backoffMs = (backoffMs * 2).clamp(500, maxBackoffMs);
      }
    }

    _polling = false;
    notifyListeners();
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
  void _recordHeard(int heardMs, int discarded, String queuedText, String why) {
    _pendingHeardMs = heardMs;

    // 就是用户给的那个式子：
    //   被打断的那条没听完的尾巴 ++ 队列里还没轮到播的整条正文
    _appendUnheard(_unheardFrom(heardMs));
    _appendUnheard(queuedText);

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
  void _appendUnheard(String? chunk) {
    final text = chunk?.trim() ?? '';
    if (text.isEmpty) return;
    _pendingUnheardText =
        _pendingUnheardText == null ? text : '$_pendingUnheardText$text';
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

    // 立刻掐掉在途的请求。
    // 尤其是那个长轮询 —— 服务端的 handler 接了 AbortSignal，
    // 我们一断开它就会取消自己的工作；不断的话它会一直挂到超时。
    _brain.abort();

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

    // 会话结束时闭麦也算结束：先把痕留下（消息列表要到下次 start 才清），
    // 免得用户看着"闭麦中"然后什么都没有。
    if (_micMuted) {
      _micMuted = false;
      _flushMuteTrace();
    }
    _mutedMs = 0;
    _pendingHeardMs = null;
    _pendingUnheardText = null;
    _replySpans = const <BrainSpan>[];
    _replyText = '';
    _replyTotalMs = 0;

    _format = null;
    _brainError = null;
    _authFailed = false;
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

  void _addMessage(MessageRole role, String text) {
    _messages.add(ConversationMessage(role: role, text: text));
    while (_messages.length > messageLimit) {
      _messages.removeAt(0);
    }
    notifyListeners();
  }

  void _append(String message) {
    _log.insert(0, LogEntry(message));
    while (_log.length > logLimit) {
      _log.removeLast();
    }
    notifyListeners();
  }

  static String _kb(int bytes) => '${(bytes / 1024).toStringAsFixed(1)}KB';

  @override
  void dispose() {
    _active = false;
    _statsTimer?.cancel();
    // 别让播放循环挂在没人叫醒的 Future 上
    _queueSignal?.complete();
    _queueSignal = null;
    _speakQueue?.dispose();
    _segmenter?.dispose();
    levelsNotifier.dispose();
    _brain.dispose();
    super.dispose();
  }
}
