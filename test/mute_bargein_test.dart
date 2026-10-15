import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/audio/segmenter.dart';
import 'package:pp_friend/src/brain/brain_client.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/conversation/message.dart';

import 'support/voice_fakes.dart';

/// 48kHz 下 20ms 一帧 = 1920 字节。闭麦时长就靠帧数堆出来。
final Uint8List _frame = Uint8List(1920);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('闭麦', () {
    test('闭麦期间喂给断句的全是数字静音，一个字节都不上传', () async {
      final engine = FakeVoiceEngine();
      final segmenter = FakeSegmenter();
      final h = await _start(engine, segmenter);
      addTearDown(() => h.dispose());

      // 先证明没闭麦时这条链路是通的
      engine.micCtrl.add(_frame);
      await pumpEventQueue();
      segmenter.emit(_segment());
      await pumpEventQueue();
      expect(engine.encodedSampleRates, [fakeSileroRate]);

      h.controller.setMicMuted(true);
      engine.encodedSampleRates.clear();
      segmenter.frames.clear();

      for (var i = 0; i < 30; i++) {
        engine.micCtrl.add(_frame);
      }
      await pumpEventQueue();

      // 静音照样喂进去（模型状态和采样节奏得连续），但全是 0
      expect(segmenter.frames, isNotEmpty);
      expect(
        segmenter.frames.every((f) => f.every((b) => b == 0)),
        isTrue,
        reason: '闭麦就是不上传，不是"上传了再撤"',
      );

      // 恶意输入：模型里可能还挂着闭麦前那半句，收尾时会切出来一段。
      // 就算切出来了，也不能放它上去。
      segmenter.emit(_segment());
      await pumpEventQueue();
      expect(engine.encodedSampleRates, isEmpty);
    });

    test('闭麦够久就留一条灰字占位，而且不写成谁说的话', () async {
      final engine = FakeVoiceEngine();
      final segmenter = FakeSegmenter();
      final h = await _start(engine, segmenter);
      addTearDown(() => h.dispose());

      engine.micCtrl.add(_frame);
      await pumpEventQueue();

      h.controller.setMicMuted(true);
      for (var i = 0; i < 30; i++) {
        engine.micCtrl.add(_frame);
      }
      await pumpEventQueue();

      h.controller.setMicMuted(false);
      await pumpEventQueue();

      // 30 帧 × 20ms = 600ms
      final last = h.controller.messages.last;
      expect(last.role, MessageRole.note);
      expect(last.text, contains('闭麦中'));
      expect(last.text, contains('0.6s'));
      expect(
        h.controller.messages.any((m) => m.role == MessageRole.user),
        isFalse,
        reason: '闭麦期间没有"人说的话"这种东西',
      );
    });

    test('闭麦不到半秒不留痕 —— 手指抖两下不该写进消息流', () async {
      final engine = FakeVoiceEngine();
      final segmenter = FakeSegmenter();
      final h = await _start(engine, segmenter);
      addTearDown(() => h.dispose());

      engine.micCtrl.add(_frame);
      await pumpEventQueue();

      h.controller.setMicMuted(true);
      engine.micCtrl.add(_frame); // 只关了 20ms
      await pumpEventQueue();
      h.controller.setMicMuted(false);
      await pumpEventQueue();

      expect(h.controller.messages, isEmpty);
    });
  });

  group('打断', () {
    test('开着打断：一开口就停播，并把"听到哪儿了"带给下一句', () async {
      final engine = FakeVoiceEngine()..opusUpstream = true;
      final segmenter = FakeSegmenter();
      final captured = <List<int>>[];
      final h = await _start(engine, segmenter, bargeIn: true, onUpload: captured.add);
      addTearDown(() => h.dispose());

      // 播放测试音 = 稳定的"AI 正在出声"，不用真的走 brain
      await h.controller.toggleTestTone();
      await pumpEventQueue();
      expect(h.controller.speaking, isTrue);

      // 已经播出去 4.2 秒
      engine.headMs = 4200;
      await _speak(engine, segmenter);

      expect(engine.flushCount, 1, reason: '你一开口就得把它停掉');
      expect(h.controller.speaking, isFalse);

      // 下一句上传时要带上 heard_ms —— brain 靠它知道自己哪段没被听到
      await h.controller.sendTestUtterance();
      await pumpEventQueue();

      expect(captured, hasLength(1));
      final body = msgpack.deserialize(Uint8List.fromList(captured.single)) as Map;
      expect(body['heard_ms'], 4200);
    });

    test('推送循环已退出、声音还在响 —— 打断照样得生效', () async {
      // 真机上就是这么栽的：整条回复几毫秒内全排进 AudioTrack 缓冲，
      // 推送循环随即退出，于是"AI 还在说"的绝大部分时间里 _speaking
      // 都是 false。打断挂在 _speaking 上，就永远不会触发。
      final engine = FakeVoiceEngine()..opusUpstream = true;
      // 1 秒 @48k 单声道 = 96000 字节，够走完一次完整的推流循环
      engine.decodedPcm = Uint8List(96000);
      final segmenter = FakeSegmenter();
      final h = await _startPlayingReply(engine, segmenter, bargeIn: true);
      addTearDown(() => h.dispose());

      await pumpEventQueue();
      await pumpEventQueue();
      expect(engine.playbackPushes, greaterThan(0), reason: '回复得真的播起来');

      // 推流循环已经退出（_speaking 为 false），但缓冲里还压着声音没响完
      engine.backlogFrames = 48000;
      engine.headMs = 4200;
      await _speak(engine, segmenter);

      expect(
        engine.flushCount,
        1,
        reason: '只看 _speaking 的话这里会漏掉，正是真机上打断没反应的原因',
      );
    });

    test('打断后，把"没听到的那几句文字"也带给下一句', () async {
      final engine = FakeVoiceEngine()..opusUpstream = true;
      engine.decodedPcm = Uint8List(96000);
      final segmenter = FakeSegmenter();
      final captured = <List<int>>[];
      final h = await _startPlayingReply(
        engine,
        segmenter,
        bargeIn: true,
        onUpload: captured.add,
      );
      addTearDown(() => h.dispose());

      await pumpEventQueue();
      await pumpEventQueue();

      // 三句各 1 秒，播到 1.5 秒被打断 —— 第二句只听了半句，也算没听到
      engine.headMs = 1500;
      engine.backlogFrames = 48000;
      await _speak(engine, segmenter);
      expect(engine.flushCount, 1);

      await h.controller.sendTestUtterance();
      await pumpEventQueue();

      expect(captured, hasLength(1));
      final body = msgpack.deserialize(Uint8List.fromList(captured.single)) as Map;
      expect(body['heard_ms'], 1500);
      expect(
        body['unheard_text'],
        '第二句。第三句。',
        reason: 'brain 要的是文字，不是毫秒 —— 它自己的对齐不用再做一遍',
      );
    });

    test('brain 没给时间账，就按比例估：倍数折到文字上，再往后找句号', () async {
      final engine = FakeVoiceEngine()..opusUpstream = true;
      // 3 秒 @48k = 288000 字节，用来当"音频总长"
      engine.decodedPcm = Uint8List(288000);
      final segmenter = FakeSegmenter();
      final captured = <List<int>>[];
      final h = await _startPlayingReply(
        engine,
        segmenter,
        bargeIn: true,
        withSpans: false,
        onUpload: captured.add,
      );
      addTearDown(() => h.dispose());

      await pumpEventQueue();
      await pumpEventQueue();

      // 3 秒播到 1.5 秒 = 一半；全文 12 字，一半就是第 6 个字。
      // 第 6 个字是"第二句"的"句"，往后找到最近的"。"（第 8 位）才切。
      engine.headMs = 1500;
      engine.backlogFrames = 48000;
      await _speak(engine, segmenter);
      expect(engine.flushCount, 1);

      await h.controller.sendTestUtterance();
      await pumpEventQueue();

      final body = msgpack.deserialize(Uint8List.fromList(captured.single)) as Map;
      expect(
        body['unheard_text'],
        '第三句。',
        reason: '估出来落在第二句中间，往后找到句号才切，不把句子劈开',
      );
    });

    test('清空时，队列里还没轮到播的那几条整条也算没听到', () async {
      // 取的那条线不等播 —— 第一条还卡在推送里，第二条早就拿到手了，
      // 就躺在队列里。
      final engine = FakeVoiceEngine()..opusUpstream = true;
      engine.decodedPcm = Uint8List(96000);
      engine.pushGate = Completer<void>();
      final segmenter = FakeSegmenter();
      final captured = <List<int>>[];
      final h = await _startPlayingReply(
        engine,
        segmenter,
        bargeIn: true,
        replyCount: 2,
        onUpload: captured.add,
      );
      addTearDown(() => h.dispose());

      for (var i = 0; i < 10; i++) {
        await pumpEventQueue();
      }

      expect(
        h.controller.messages.where((m) => m.role == MessageRole.assistant).length,
        2,
        reason: '第二条已经到手，排在第一條后面等着播',
      );
      expect(engine.playbackPushes, 1, reason: '第一条还卡在推送里，第二条还没轮到');

      // 第一条播到 1.5 秒时手动清空（不是打断，用户没说话）
      engine.headMs = 1500;
      engine.backlogFrames = 48000;
      await h.controller.clearPlayback();
      await pumpEventQueue();

      // 放行推送，让第一条的循环收尾，别挂着测试
      engine.pushGate!.complete();
      engine.pushGate = null;

      await h.controller.sendTestUtterance();
      await pumpEventQueue();

      final body = msgpack.deserialize(Uint8List.fromList(captured.single)) as Map;
      expect(body['heard_ms'], 1500);
      expect(
        body['unheard_text'],
        '第二句。第三句。第一句。第二句。第三句。',
        reason: '第一条没听完的尾巴 ++ 队列里还没轮到播的整条正文',
      );
    });

    test('你还在说的时候新到的回复先不播，整条算没听到', () async {
      final engine = FakeVoiceEngine()..opusUpstream = true;
      engine.decodedPcm = Uint8List(96000);
      // 把"正在播第一条"这个状态按住：不然假引擎里推送是瞬时的，
      // 还没等我们开口，第一条早播完、第二条也已经播上了。
      engine.pushGate = Completer<void>();
      final segmenter = FakeSegmenter();
      final captured = <List<int>>[];
      final h = await _startPlayingReply(
        engine,
        segmenter,
        bargeIn: true,
        replyCount: 2,
        onUpload: captured.add,
      );
      addTearDown(() => h.dispose());

      await pumpEventQueue();

      expect(h.controller.speaking, isTrue, reason: '第一条正卡在推送里');

      // 用户开口，打断第一条；注意**不**收尾那句，所以人还在说
      engine.headMs = 1500;
      engine.backlogFrames = 48000;
      await _speak(engine, segmenter);

      // 放行推送：第一条的循环这才走到头，轮询紧接着去要下一条 ——
      // 而此时用户还在说
      engine.pushGate!.complete();
      engine.pushGate = null;
      for (var i = 0; i < 10; i++) {
        await pumpEventQueue();
      }

      expect(
        h.controller.messages.where((m) => m.role == MessageRole.assistant).length,
        2,
        reason: '第二条得真的到了，才谈得上"没播"',
      );
      expect(
        engine.playbackPushes,
        1,
        reason: '播下去也没人拦得住（没有第二次"开口"事件），只会盖在人家说话上面',
      );

      await h.controller.sendTestUtterance();
      await pumpEventQueue();

      final body = msgpack.deserialize(Uint8List.fromList(captured.single)) as Map;
      expect(
        body['unheard_text'],
        '第二句。第三句。第一句。第二句。第三句。',
        reason: '第一条的尾巴 ++ 第二条整段正文',
      );
    });

    test('咳嗽一声不算说话 —— 不该把 AI 打断', () async {
      // Silero 一判到有声就立刻 `speaking=true`，而且一直扛到收尾那段静音
      // （默认 700ms）结束 —— 跟这段声音本身多长毫无关系。所以咳嗽、
      // 清嗓子、叹口气，如果只看"开口了没"，都是一声就让 AI 让位。
      final engine = FakeVoiceEngine()..opusUpstream = true;
      final segmenter = FakeSegmenter();
      final h = await _start(engine, segmenter, bargeIn: true);
      addTearDown(() => h.dispose());

      await h.controller.toggleTestTone();
      await pumpEventQueue();
      expect(h.controller.speaking, isTrue);

      // 20ms 一帧，喂 5 帧 = 100ms：一声咳嗽的量级
      await _speak(engine, segmenter, frames: 5);

      expect(
        engine.flushCount,
        0,
        reason: '100ms 连"嗯"都算不上，不能凭这一下就把话掐了',
      );
      expect(h.controller.speaking, isTrue, reason: 'AI 该继续说下去');
    });

    test('关着打断：开口不停播，请求里也不带 heard_ms', () async {
      final engine = FakeVoiceEngine()..opusUpstream = true;
      final segmenter = FakeSegmenter();
      final captured = <List<int>>[];
      final h = await _start(engine, segmenter, onUpload: captured.add);
      addTearDown(() => h.dispose());

      await h.controller.toggleTestTone();
      await pumpEventQueue();

      engine.headMs = 4200;
      await _speak(engine, segmenter);

      // handoff §A5 的默认行为：收到就播，不做自动打断
      expect(engine.flushCount, 0);
      expect(h.controller.speaking, isTrue);

      await h.controller.sendTestUtterance();
      await pumpEventQueue();

      expect(captured, hasLength(1));
      final body = msgpack.deserialize(Uint8List.fromList(captured.single)) as Map;
      // "没被打断"和"听到了 0ms"是两件事，所以这个键根本不该出现
      expect(body.containsKey('heard_ms'), isFalse);
    });
  });
}

// ---------------------------------------------------------------------------

SpeechSegment _segment() => SpeechSegment(
      pcm16le: Uint8List(320),
      sampleRate: fakeSileroRate,
      durationSeconds: 0.3,
    );

/// 模拟"用户连着说了 [frames] 帧"。
///
/// 每帧 [_frame] 是 48000Hz 下的 20ms。打断不是"一有声就出手"了 ——
/// 得连续够长才算数（见 `bargeInMinSpeechMs`），所以这里必须真的喂帧、
/// 而不是只抛一个 onSpeechStart。
Future<void> _speak(
  FakeVoiceEngine engine,
  FakeSegmenter segmenter, {
  int frames = 20,
}) async {
  segmenter.statsValue = const SegmenterStats(speaking: true, probability: 0.9);
  for (var i = 0; i < frames; i++) {
    engine.micCtrl.add(_frame);
  }
  await pumpEventQueue();
  segmenter.statsValue = SegmenterStats.idle;
}

class _Harness {
  _Harness(this.controller, this.engine);

  final ConversationController controller;
  final FakeVoiceEngine engine;

  Future<void> dispose() async {
    await controller.stop();
    engine.close();
  }
}

/// 起一个已经跑起来的 controller。
///
/// [onUpload] 收 /human-to-brain 的请求体；/brain-to-human 一律 503，
/// 让轮询走退避分支，不插进来抢 _speaking。
Future<_Harness> _start(
  FakeVoiceEngine engine,
  FakeSegmenter segmenter, {
  bool bargeIn = false,
  void Function(List<int> body)? onUpload,
}) async {
  final brain = BrainClient(
    client: MockClient((request) async {
      if (request.url.path.endsWith('/brain-to-human')) {
        return http.Response('', 503);
      }
      onUpload?.call(request.bodyBytes);
      return http.Response.bytes(
        msgpack.serialize(<String, dynamic>{'kind': 'text', 'text': '收到'}),
        200,
        headers: {'content-type': 'application/msgpack'},
      );
    }),
  );

  final controller = ConversationController(
    engine: engine,
    brain: brain,
    segmenterFactory: ({required int sampleRate, required AssistantConfig config}) async {
      segmenter.sampleRates.add(sampleRate);
      return segmenter;
    },
  );
  await controller.updateConfig(
    AssistantConfig(
      brain: const BrainConfig(baseUrl: 'http://test.local:8000', brainId: '测试'),
      bargeIn: bargeIn,
    ),
  );
  await controller.start();
  return _Harness(controller, engine);
}

/// 起一个 controller，并让它收到**一条带音频的回复**。
///
/// 和 [_start] 的区别：这里真的会走 `_playReplyAudio` 那条路，也就是
/// 真机上"声音在响但 `_speaking` 已经落回 false"的那个状态。
Future<_Harness> _startPlayingReply(
  FakeVoiceEngine engine,
  FakeSegmenter segmenter, {
  bool bargeIn = false,
  bool withSpans = true,
  int replyCount = 1,
  void Function(List<int> body)? onUpload,
}) async {
  var served = 0;
  final brain = BrainClient(
    client: MockClient((request) async {
      if (!request.url.path.endsWith('/brain-to-human')) {
        onUpload?.call(request.bodyBytes);
        return http.Response.bytes(
          msgpack.serialize(<String, dynamic>{'kind': 'text', 'text': '收到'}),
          200,
          headers: {'content-type': 'application/msgpack'},
        );
      }
      // 喂几条就停，之后再问就是"暂时没话说"，别插进来抢播放状态
      if (served >= replyCount) return http.Response('', 503);
      served++;
      return http.Response.bytes(
        msgpack.serialize(<String, dynamic>{
          'kind': 'text',
          'text': '第一句。第二句。第三句。',
          'audio': Uint8List.fromList(const <int>[1, 2, 3, 4]),
          // 按句的时间账：三句各 1 秒。客户端靠它把"播到第几毫秒"
          // 翻成"哪几句没听到"。
          if (withSpans)
            'spans': [
              {'text': '第一句。', 'ms': 1000},
              {'text': '第二句。', 'ms': 1000},
              {'text': '第三句。', 'ms': 1000},
            ],
        }),
        200,
        headers: {'content-type': 'application/msgpack'},
      );
    }),
  );

  final controller = ConversationController(
    engine: engine,
    brain: brain,
    segmenterFactory: ({required int sampleRate, required AssistantConfig config}) async {
      segmenter.sampleRates.add(sampleRate);
      return segmenter;
    },
  );
  await controller.updateConfig(
    AssistantConfig(
      brain: const BrainConfig(baseUrl: 'http://test.local:8000', brainId: '测试'),
      bargeIn: bargeIn,
    ),
  );
  await controller.start();
  return _Harness(controller, engine);
}
