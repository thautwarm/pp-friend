import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/audio/segmenter.dart';
import 'package:pp_friend/src/brain/brain_client.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/voice/voice_engine.dart';

import 'support/voice_fakes.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('ConversationController × Segmenter', () {
    test('segmenter 在订阅 micPcm 之前就构造好了', () async {
      final order = <String>[];
      final engine = FakeVoiceEngine(order);
      final segmenter = FakeSegmenter();
      final controller = await _start(engine, _factory(order, segmenter));

      addTearDown(() async {
        await controller.stop();
        engine.close();
      });

      // 加载 1.26MB 模型是几十到几百毫秒。要是等订阅完 micPcm 再建，
      // 这段丢音就落在最开头 —— 用户第一句话必然被吞。
      expect(order.indexOf('segmenter'), isNonNegative);
      expect(order.indexOf('micSub'), isNonNegative);
      expect(order.indexOf('segmenter'), lessThan(order.indexOf('micSub')));

      // 拿到的必须是**采集率**：Rust 侧要按它决定重采样比。
      expect(segmenter.sampleRates, [fakeCaptureRate]);
    });

    test('入队用的是 segment 自带的采样率，不是采集率', () async {
      final order = <String>[];
      final engine = FakeVoiceEngine(order);
      final segmenter = FakeSegmenter();
      final controller = await _start(engine, _factory(order, segmenter));

      addTearDown(() async {
        await controller.stop();
        engine.close();
      });

      // 先喂一帧，controller 的回调是在 feed 里递进来的。
      engine.micCtrl.add(Uint8List(1920));
      await pumpEventQueue();

      segmenter.emit(
        SpeechSegment(
          pcm16le: Uint8List(320),
          sampleRate: fakeSileroRate,
          durationSeconds: 0.01,
        ),
      );
      await pumpEventQueue();

      // 采集率是 48000，但这段音频是 Silero 重采样出来的 16k。
      // 写成 format.sampleRate 的话，会发出 48k 的 Ogg，而规范只收 16kHz ——
      // 服务端拒收，报错离现场很远，这条回归就是拦它的。
      expect(engine.encodedSampleRates, [fakeSileroRate]);
    });

    test('AI 出声且麦克风没盖过播放电平时，喂给断句的是数字静音', () async {
      final order = <String>[];
      final engine = FakeVoiceEngine(order);
      final segmenter = FakeSegmenter();
      final controller = await _start(engine, _factory(order, segmenter));

      addTearDown(() async {
        await controller.stop();
        engine.close();
      });

      // 播放测试音 = 稳定的"AI 正在出声"，不用真的走 brain。
      await controller.toggleTestTone();
      await pumpEventQueue();

      // 麦克风比播放低 40dB：这是 AEC 的残留回声，不是人在说话。
      engine.levelCtrl.add(const AudioLevels(micDb: -60, playbackDb: -20));
      await pumpEventQueue();

      segmenter.frames.clear();
      engine.micCtrl.add(Uint8List.fromList(List<int>.generate(64, (i) => i + 1)));
      await pumpEventQueue();

      expect(segmenter.frames, isNotEmpty, reason: '静音也要喂，模型状态得继续推进');
      expect(
        segmenter.frames.last.every((b) => b == 0),
        isTrue,
        reason: 'Silero 会把 AI 自己的声音判成说话，不拦住就是自激循环',
      );

      // 反向：你明显盖过播放电平（双讲），必须原样放行，不能误吞。
      engine.levelCtrl.add(const AudioLevels(micDb: -10, playbackDb: -20));
      await pumpEventQueue();

      final real = Uint8List.fromList(List<int>.generate(64, (i) => i + 1));
      segmenter.frames.clear();
      engine.micCtrl.add(real);
      await pumpEventQueue();

      expect(segmenter.frames.last, real);
    });

    test('断句引擎加载失败：报错可见，且完全不收麦克风', () async {
      final order = <String>[];
      final engine = FakeVoiceEngine(order);
      final controller = await _start(engine, _failFactory(order));

      addTearDown(() async {
        await controller.stop();
        engine.close();
      });

      // 能量 VAD 已经删了，没有能顶上来的备胎 —— 这里必须显式失败，
      // 而不是"点了开始、界面一切正常、你说什么都毫无反应"。
      expect(controller.active, isFalse);
      expect(controller.segmenterError, isNotNull);
      expect(engine.micListenCount, 0);
      expect(
        controller.log.any((e) => e.message.contains('加载失败')),
        isTrue,
      );
    });
  });
}

// ---------------------------------------------------------------------------

/// 起一个已经跑起来的 controller。
///
/// 必须先填 brain 配置 —— 不填的话 `start()` 在"brain 地址没填"那里就返回了，
/// 走不到任何断句逻辑，测试会以最迷惑的方式通过。
Future<ConversationController> _start(
  VoiceEngine engine,
  SegmenterFactory factory,
) async {
  final controller = ConversationController(
    engine: engine,
    // 503 让轮询循环走退避分支而不是空转，测试期间不会真的打网络。
    brain: BrainClient(client: MockClient((_) async => http.Response('', 503))),
    segmenterFactory: factory,
  );
  await controller.updateConfig(
    const AssistantConfig(
      brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: '测试'),
    ),
  );
  await controller.start();
  return controller;
}

SegmenterFactory _factory(List<String> order, FakeSegmenter segmenter) =>
    ({required int sampleRate, required AssistantConfig config}) async {
      order.add('segmenter');
      segmenter.sampleRates.add(sampleRate);
      segmenter.configs.add(config);
      return segmenter;
    };

SegmenterFactory _failFactory(List<String> order) =>
    ({required int sampleRate, required AssistantConfig config}) async {
      order.add('segmenter');
      throw StateError('librust_lib_pp_friend.so not found');
    };
