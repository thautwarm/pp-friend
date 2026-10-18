import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../brain/brain_client.dart';
import '../brain/voice_directives.dart';
import '../config/profile.dart';
import '../storage/message_store.dart';
import 'message.dart';

/// 一个档案的运行态：自己的 brain 连接、自己的消息历史、自己的错误状态。
///
/// **为什么档案不是各自一个 [ConversationController]**：麦克风、扬声器、
/// 前台服务在整机上都只有一份。挂三个 controller 就是三路 AudioRecord，
/// 同一帧麦克风数据会被三个 segmenter 各切一遍、各上传一次。所以音频管线
/// 归 controller 独有，而这里装的是**真正可以有多份**的东西 —— 一个 HTTP
/// 长轮询、一份历史、一个错误状态。
///
/// 于是"多个档案同时在跑"的准确含义是**多条轮询同时在跑**，音频只服务
/// 其中聚焦的那一个：
///
/// | 状态 | 轮询 | 上行 | 播放 | 记历史 |
/// |---|---|---|---|---|
/// | 聚焦 | 跑 | 跑 | 播 | 记 |
/// | 未聚焦但激活 | 跑 | 不跑 | **丢掉** | 记 |
/// | 关闭 | 不跑 | 不跑 | 不播 | 不记 |
///
/// 第二行第一列的"不跑上行"不是靠某个 if 挡住的，是**结构上没有**：
/// 采集、断句、上传那条链路整个挂在 controller 上，未聚焦的档案里根本
/// 不存在这些东西。挡在调用点前面的 if 迟早会被新加的调用点绕过。
class ProfileRuntime {
  ProfileRuntime({
    required this.profile,
    required this.brain,
    required this.store,
    required this.onChanged,
    required this.onLog,
    required this.isActive,
    required this.isFocused,
    required this.onReply,
    this.messageLimit = 300,
  });

  /// 这个档案当前的样子。配置改了之后由 [updateProfile] 换掉。
  Profile profile;

  String get id => profile.id;
  String get displayName => profile.displayName;

  /// 这个档案自己的 HTTP 客户端。
  ///
  /// **必须每个档案一个。** [BrainClient.abort] 的语义是"关掉底层 client
  /// 并换一个新的"，共享一个的话，停掉 A 的长轮询会把 B 那条一起打断。
  final BrainClient brain;

  final MessageStore store;

  final VoidCallback onChanged;
  final void Function(String message) onLog;

  /// 会话是否开着（controller 的 `_active`）。
  final bool Function() isActive;

  /// 这个档案现在是不是聚焦的那个。**每次用的时候现读**，别缓存 ——
  /// 长轮询可以挂一百多秒，这期间用户完全可能切走。
  final bool Function() isFocused;

  /// 把一条回复的句柄交给控制器。只有聚焦的档案会走到这里。
  ///
  /// 第一帧已经由本类记进消息流；控制器只负责从 [start] 之后继续消费
  /// [stream.events]，逐帧解码、推送，并在被打断时把流取消。
  final Future<void> Function(BrainReplyStream stream, BrainReplyStart start)
  onReply;

  /// 内存里最多留多少条。超了就从头裁掉 —— 盘上还在，往上翻能读回来。
  final int messageLimit;

  final List<ConversationMessage> _messages = <ConversationMessage>[];

  /// 零拷贝视图。原来的 `List.unmodifiable` 每次访问都复制整个列表，
  /// 而界面在一次 build 里会读好几遍，还每 500ms 重建一次。
  List<ConversationMessage> get messages => UnmodifiableListView(_messages);

  /// 盘上还有更早的没读进来。
  bool get hasMoreBefore => _hasMoreBefore;
  bool _hasMoreBefore = false;

  /// 这个档案的历史从盘上读过了。
  ///
  /// 界面靠它区分"**没有**历史"（该显示引导语）和"历史还没读出来"
  /// （什么都别显示）。少了它，冷启动时会先闪一下"直接说话就行"，
  /// 过一帧历史才冒出来。
  bool get loaded => _loaded;
  bool _loaded = false;

  /// 最新一条的 seq。界面靠它判断"是不是来了新消息"。
  ///
  /// **不能拿消息条数代替**：内存窗口满了之后条数就不再增长（自动滚动会
  /// 静默失效），而往上翻历史又会让条数变大（会被误判成新消息，把用户
  /// 从历史里拽回底部）。
  int get lastSeq => _messages.isEmpty ? 0 : _messages.last.seq;

  bool polling = false;
  String? error;
  bool authFailed = false;

  bool _running = false;

  /// 轮询代数。每次 start/stop 都自增，旧循环回来时据此知道自己已经作废，
  /// 不会把新一轮的状态（`_running` / `polling`）又按回 false。
  int _pollGeneration = 0;

  /// 循环正睡在退避里时，用它把人叫醒。见 [_backoff]。
  Completer<void>? _wake;

  /// 这条轮询正在跑。用来避免重复 start。
  bool get running => _running;

  /// 收到多少条语音被丢掉了。用来把日志压成一条，而不是每条回复刷一行。
  int _skippedAudio = 0;

  /// 正在读的这条 `/brain-to-human` 流。打断/停轮询时用它主动断开，
  /// 让服务端立刻停止后续合成。
  BrainReplyStream? _currentStream;

  /// 用户打断时设下的水位（UTC epoch 毫秒）。
  ///
  /// 服务端把打断**之前**入队的消息跳过：不合成音频，一条消息一条
  /// `skipped` 首帧。客户端把它们的文本显示出来，并记进没听到。
  /// 收到下一条真回复后清掉。
  ///
  /// **只在用户打断时设置**（开口盖过 AI、通知栏停止说话、音量减键）。
  /// 会话开始、切档案、结束对话都不设置 —— 停着的时候积压的消息
  /// 必须原样送达，不能悄悄吞掉。
  int? _skipBeforeMs;

  /// 这次打断之后已经跳过了几条。只用来把日志压成一条。
  int _skippedSinceInterrupt = 0;

  /// 连续截断了几次。截断本身立刻重发，但坏服务端不能把循环打成忙等。
  int _truncatedStreak = 0;

  /// 因为打断而主动掐断了在途请求：下一次循环立刻重发，不记错误、不退避。
  bool _retryNow = false;

  /// 网络失败的重试退避上限（毫秒）。
  static const int maxBackoffMs = 15000;

  // ------------------------------------------------------------ 发送侧要用的账

  /// 上一段 AI 语音里用户实际听到了多少毫秒，挂着等下一次上传带过去。
  int? pendingHeardMs;

  /// 攒着没上报的"没听到的那部分文字"。
  ///
  /// **必须跟着档案走。** 挂在 controller 上的话，在 A 里打断攒下的账
  /// 会跟着下一次上传发给 B —— 这是整个改造里最隐蔽的一个 bug。
  String? pendingUnheardText;

  void appendUnheard(String? chunk) {
    final text = chunk?.trim();
    if (text == null || text.isEmpty) return;
    pendingUnheardText = pendingUnheardText == null
        ? text
        : '$pendingUnheardText$text';
  }

  /// 用户打断了 AI 说话。记下此刻，让服务端跳过打断之前入队的消息。
  ///
  /// 三个触发源：开口盖过 AI（barge-in）、通知栏「停止说话」、
  /// 前台的音量减键。**都算打断。** 打断之后新入队的回复照常送达。
  void markInterrupted() {
    _skipBeforeMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    _skippedSinceInterrupt = 0;

    // 正在等前导的那次长轮询是**打断之前**发出去的，没有带这个水位：
    // 服务端随时可能把打断前就排队的消息塞回来，而客户端会照单全收。
    // 直接掐断这条请求，让循环带着新的 skip_before 立刻重发。
    // 已经在播的流不走这里 —— 那条由 controller 的 _beginInterrupt 取消。
    if (_currentStream == null && _running && brain.hasPendingRequests) {
      _retryNow = true;
      brain.abort();
    }
  }

  /// 换了一份配置之后更新。
  void updateProfile(Profile updated) {
    profile = updated;
  }

  // ------------------------------------------------------------ 历史

  /// 从盘上读回最近的一段。会话开始时、换到这个档案时各调一次。
  ///
  /// **按 seq 合并，不直接清空重填。** 读盘是异步的，而这条档案的轮询
  /// 一直在跑：读的这几十毫秒里完全可能刚好收到一条回复并落进内存。
  /// 清空重填会把它抹掉 —— 盘上有、内存里没有，要等下次读盘或者重启才
  /// 回来，看起来就是"它刚才说的话不见了"。
  Future<void> load() async {
    List<ConversationMessage> recent;
    try {
      recent = await store.loadRecent(id, limit: messageLimit);
    } catch (e) {
      onLog('⚠️ 读历史失败：$e');
      recent = const [];
    }

    final merged = <ConversationMessage>[...recent];
    final newestLoaded = merged.isEmpty ? 0 : merged.last.seq;
    for (final message in _messages) {
      // 只接"盘上还没有的"。seq == 0 是没落住盘的那种（写入失败），
      // 这里跟着丢掉 —— 它本来就不在盘上，重读一次找不回来是正常的。
      if (message.seq > newestLoaded) merged.add(message);
    }

    _messages
      ..clear()
      ..addAll(merged);
    _refreshHasMore();
    _loaded = true;
    onChanged();
  }

  /// 往上翻一页。
  Future<void> loadOlder({int limit = 50}) async {
    if (_messages.isEmpty) return;
    final before = _messages.first.seq;
    List<ConversationMessage> older;
    try {
      older = await store.loadOlder(id, beforeSeq: before, limit: limit);
    } catch (e) {
      onLog('⚠️ 读更早的历史失败：$e');
      return;
    }
    if (older.isEmpty) {
      _hasMoreBefore = false;
      onChanged();
      return;
    }
    _messages.insertAll(0, older);
    _refreshHasMore();
    onChanged();
  }

  /// 前面还有没有更早的。
  ///
  /// **不查盘。** seq 是从 1 开始一条一条加上去的（清空会一起归零），所以
  /// "还有更早的"就等于"当前最早那条的 seq 不是 1"。
  ///
  /// 这里以前是拿 `loadOlder(limit: 1)` 去问的，而那要从最新那个分片往回
  /// 把所有分片解析一遍才找得出一条 —— 冷启动为了显示最近 300 条，得把
  /// 整年的历史读一遍，而且是在主 isolate 上同步解析。
  void _refreshHasMore() {
    _hasMoreBefore = _messages.isNotEmpty && _messages.first.seq > 1;
  }

  /// 落一条消息。
  ///
  /// **先落盘再进内存**，seq 由 store 发。这样内存里的 seq 和盘上永远一致，
  /// 重启之后接着发号也不会撞。代价是消息要等一次磁盘写才上屏（几毫秒，
  /// 看不出来）。
  Future<void> record(MessageRole role, String text) async {
    ConversationMessage message;
    try {
      message = await store.append(id, role: role, text: text);
    } catch (e) {
      // 落盘失败不能连累界面：消息照进内存，只是这次会话结束之后它就不在了。
      onLog('⚠️ 消息没能落盘：$e');
      message = ConversationMessage(role: role, text: text);
    }
    _messages.add(message);
    while (_messages.length > messageLimit) {
      _messages.removeAt(0);
    }
    onChanged();
  }

  /// 清空历史。盘上和内存一起清。
  Future<void> clearHistory() async {
    try {
      await store.clear(id);
    } catch (e) {
      onLog('⚠️ 清历史失败：$e');
      return;
    }
    _messages.clear();
    _hasMoreBefore = false;
    onChanged();
  }

  // ------------------------------------------------------------ 轮询

  void startPolling() {
    if (_running) return;
    _running = true;
    _skippedAudio = 0;
    _truncatedStreak = 0;
    // **不设 skip_before。** 停着的时候服务端压下来的消息必须原样送上来：
    // 有文本也有音频，用户能看见、能听见。只有用户主动打断才该丢。
    _skipBeforeMs = null;
    _skippedSinceInterrupt = 0;
    unawaited(_pollLoop(++_pollGeneration));
  }

  /// 取消当前在途的回复流。barge-in、清空、切档案、停轮询都走这里。
  ///
  /// **这不是网络错误。** 服务端看到连接断开会立刻停止后续合成，
  /// 已经取走的这条不会重投。
  Future<void> cancelCurrentReply() async {
    final stream = _currentStream;
    _currentStream = null;
    await stream?.cancel();
  }

  Future<void> stopPolling() async {
    if (!_running) return;
    _running = false;
    // 作废当前这一轮。**不等它退出来**：它可能正卡在一次已经不可取消的
    // 原生推送里（解码/推 AudioTrack），等下去会把结束对话、关档案、
    // 保存配置全拖住。网络这一侧由 cancelCurrentReply + abort 立刻掐断，
    // 剩下的只是本地收尾；旧循环回来后会看到代数变了，自己安静退出。
    _pollGeneration++;
    // 先取消当前流，再关 client。两步都会让在途请求立刻断掉；
    // 顺序反了也没错，但先取消能把"客户端主动断"这个语义传清楚。
    await cancelCurrentReply();
    brain.abort();
    // 退避里的 `Future.delayed` 它打不断 —— 叫醒它，让旧循环尽快走完。
    _wake?.complete();
    polling = false;
    onChanged();
  }

  /// 退避等待，可以被 [stopPolling] 提前叫醒。
  ///
  /// 不能直接用 `Future.delayed`：那段时间里循环是"活着但叫不动"的，
  /// 而 stopPolling 会 `await` 它。
  Future<void> _backoff(int ms) async {
    final wake = Completer<void>();
    _wake = wake;
    try {
      await Future.any(<Future<void>>[
        Future<void>.delayed(Duration(milliseconds: ms)),
        wake.future,
      ]);
    } finally {
      _wake = null;
    }
  }

  Future<void> dispose() async {
    await stopPolling();
    brain.dispose();
  }

  Future<void> _pollLoop(int generation) async {
    // 起跑之前就已经被 stop 掉了：别把 polling 又立起来。
    if (generation != _pollGeneration) return;
    polling = true;
    onChanged();

    var backoffMs = 500;

    loop:
    while (_running && isActive() && generation == _pollGeneration) {
      BrainReplyStream? stream;
      try {
        stream = await brain.brainToHuman(
          baseUrl: profile.brain.baseUrl,
          brainId: profile.brain.brainId,
          token: profile.brain.token,
          // 只在用户打断之后带；收到下一条真回复才清掉。
          skipBefore: _skipBeforeMs,
        );

        if (!_running || !isActive() || generation != _pollGeneration) {
          await stream.cancel();
          break;
        }

        _currentStream = stream;
        backoffMs = 500;
        setError(null);

        final first = stream.first;

        if (first is BrainEmpty) {
          final skipped = first.skippedText;
          if (skipped != null && skipped.trim().isNotEmpty) {
            // 打断之后服务端跳过了一条旧消息（没有合成音频）。
            // 文本照样显示出来，并记进没听到 —— 用户说"文本不能漏"。
            _skippedSinceInterrupt++;
            if (_skippedSinceInterrupt == 1) {
              onLog('打断后跳过旧消息：文本照常显示，并记进没听到');
            }
            await record(MessageRole.assistant, skipped);
            appendUnheard(spokenText(skipped));
          }
          await stream.cancel();
          continue loop;
        }

        final start = first as BrainReplyStart;

        // 真回复到了，打断水位结束（被跳过的消息已经全部送达）。
        if (_skipBeforeMs != null) {
          if (_skippedSinceInterrupt > 0) {
            onLog('打断后一共跳过 $_skippedSinceInterrupt 条旧消息（文本已显示）');
          }
          _skipBeforeMs = null;
          _skippedSinceInterrupt = 0;
        }

        // 拿到真回复就算从截断里恢复；不要求整条播放完。
        _truncatedStreak = 0;

        // 文本永远进消息流，无论音频后面会不会被清掉。
        if (start.text.trim().isNotEmpty) {
          await record(MessageRole.assistant, start.text);
        }

        if (!_running || !isActive() || generation != _pollGeneration) {
          await stream.cancel();
          break;
        }

        if (!isFocused()) {
          // 收到第一帧的那一刻**现读**聚焦状态。缓存下来的话，
          // 会出现"切走之后旧档案的声音还在响"。
          //
          // 只记第一条：后台档案可能连着来好几条，每条都写一行会
          // 把这个 120 条的调试环刷没。
          if (_skippedAudio++ == 0) {
            onLog('$displayName 收到回复，但它没在聚焦，音频不播');
          }
          // 服务端看到断开就会停止后续合成。文字已经记下了，
          // 音频本来就不要，没必要继续下载。
          await stream.cancel();
          continue loop;
        }

        _skippedAudio = 0;
        await onReply(stream, start);
      } on BrainException catch (e) {
        if (!_running || !isActive() || generation != _pollGeneration) break;
        if (_retryNow) {
          _retryNow = false;
          continue loop;
        }

        if (e.kind == BrainErrorKind.truncated) {
          // 截断不是网络故障：已经取走的帧不重投，重新发一次请求
          // 就能接着拿后面的内容。连续多次时稍微让一下，避免忙等。
          _truncatedStreak++;
          onLog(
            '回复流被截断，立刻重新请求'
            '${_truncatedStreak > 1 ? "（连续 $_truncatedStreak 次）" : ""}',
          );
          if (_truncatedStreak >= 3) {
            await _backoff(200);
          }
          continue loop;
        }

        setError(e.message);
        onLog(e.message);

        // 401 是配置错误，重试只会把它变成持续请求 —— 停下并提示
        if (e.kind == BrainErrorKind.auth) {
          authFailed = true;
          onLog('⚠️ 鉴权失败，已停止轮询。检查配置里的 token。');
          break;
        }

        onLog('${backoffMs}ms 后重试');
        await _backoff(backoffMs);
        backoffMs = (backoffMs * 2).clamp(500, maxBackoffMs);
      } catch (e) {
        if (!_running || !isActive() || generation != _pollGeneration) break;
        if (_retryNow) {
          // 我们为了带上新的 skip_before 主动掐的，不是故障。
          _retryNow = false;
          continue loop;
        }
        onLog('/brain-to-human 异常：$e');
        await _backoff(backoffMs);
        backoffMs = (backoffMs * 2).clamp(500, maxBackoffMs);
      } finally {
        final current = _currentStream;
        if (identical(current, stream)) _currentStream = null;
      }
    }

    // 循环自己退出来了（鉴权失败 break，或者档案被关掉/删掉）。
    // **`_running` 必须一起复位**：它是 `startPolling` 的幂等闸，
    // 留着 true 的话就成了"循环已经死了，外面却以为它还在跑"——
    // 用户把 token 改对、保存，`_syncPolling` 见 running 为 true 直接跳过，
    // 这个档案就再也不会有任何回复了。
    //
    // **只在代数没变时复位状态。** 旧循环可能在 stop 之后才从一次不可取消的
    // 原生推送里回来；那时新循环可能已经起来了，不认识的旧人不能把
    // `_running` 按回 false，否则新循环会变成"外面以为它在跑、其实已经
    // 被自己人关了"。
    if (generation == _pollGeneration) {
      _running = false;
      polling = false;
      onChanged();
    }
  }

  /// 记下（或者清掉）这个档案最近一次失败的原因。
  void setError(String? message) {
    if (error == message) return;
    error = message;
    onChanged();
  }
}
