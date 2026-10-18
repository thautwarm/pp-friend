import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/audio/segmenter.dart';
import 'package:pp_friend/src/brain/brain_client.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/storage/voiceprint_store.dart';

import 'support/config_fakes.dart';
import 'support/voice_fakes.dart';

/// 造一份合法的声纹：192 个 float32，L2 范数为 1。
Uint8List _spkemb({double first = 1.0}) {
  final data = ByteData(Voiceprint.byteLength);
  data.setFloat32(0, first, Endian.little);
  return data.buffer.asUint8List();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('声纹文件', () {
    test('只认 768 字节', () {
      expect(() => Voiceprint.parse(Uint8List(767)), throwsFormatException);
      expect(() => Voiceprint.parse(Uint8List(769)), throwsFormatException);
      expect(Voiceprint.parse(_spkemb()).bytes.length, 768);
    });

    test('零向量和 NaN 都拒绝', () {
      expect(
        () => Voiceprint.parse(Uint8List(Voiceprint.byteLength)),
        throwsFormatException,
      );
      final nan = ByteData(Voiceprint.byteLength)
        ..setFloat32(0, double.nan, Endian.little);
      expect(
        () => Voiceprint.parse(nan.buffer.asUint8List()),
        throwsFormatException,
      );
    });

    test('存下来再读出来，字节完全一致', () async {
      final root = await Directory.systemTemp.createTemp('vp_test');
      addTearDown(() => root.delete(recursive: true));
      final store = VoiceprintStore(root);
      final bytes = _spkemb(first: 0.6);

      expect(await store.load(), isNull, reason: '没导入之前就是没有');
      await store.save(Voiceprint.parse(bytes));
      expect(await store.exists(), isTrue);

      final loaded = await store.load();
      expect(loaded, isNotNull);
      expect(loaded!.bytes, bytes);

      await store.clear();
      expect(await store.load(), isNull);
    });

    test('文件坏了就当没有，不抛', () async {
      final root = await Directory.systemTemp.createTemp('vp_bad');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/voiceprint/spkemb.f32');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);

      expect(await VoiceprintStore(root).load(), isNull);
    });
  });

  group('接进 controller', () {
    test('没有声纹时不挂门控，只记一行日志', () async {
      final h = await _boot();
      addTearDown(h.dispose);

      await h.controller.start();

      expect(h.segmenter.gateAttachCount, 0);
      expect(
        h.controller.log.map((e) => e.message).join('\n'),
        contains('还没导入声纹'),
      );
    });

    test('导入声纹之后启动，会按配置的阈值挂上', () async {
      final h = await _boot(threshold: 0.7, minRatio: 0.6);
      addTearDown(h.dispose);

      await h.controller.importVoiceprint(_spkemb());
      await h.controller.start();

      expect(h.segmenter.gateAttachCount, 1);
      expect(h.segmenter.gateVoiceprint, _spkemb());
      expect(h.segmenter.gateThreshold, 0.7);
      expect(h.segmenter.gateMinTargetRatio, 0.6);
      expect(h.controller.hasVoiceprint, isTrue);
    });

    test('对话中导入，立刻生效，不用重开', () async {
      final h = await _boot();
      addTearDown(h.dispose);

      await h.controller.start();
      expect(h.segmenter.gateAttachCount, 0);

      await h.controller.importVoiceprint(_spkemb());
      expect(h.segmenter.gateAttachCount, 1);
    });

    test('关掉开关就摘掉门控；打开再挂回来', () async {
      final h = await _boot(pvadEnabled: false);
      addTearDown(h.dispose);

      await h.controller.importVoiceprint(_spkemb());
      await h.controller.start();
      expect(h.segmenter.gateAttachCount, 0, reason: '开关关着就不该挂');

      await h.controller.updateConfig(
        h.controller.config.copyWith(pvadEnabled: true),
      );
      expect(h.segmenter.gateAttachCount, 1);

      // 启动时"开关关着"那一下也 detach 过一次，所以比较增量。
      final detaches = h.segmenter.gateDetachCount;
      await h.controller.updateConfig(
        h.controller.config.copyWith(pvadEnabled: false),
      );
      expect(h.segmenter.gateDetachCount, detaches + 1);
    });

    test('删除声纹之后立刻摘掉门控', () async {
      final h = await _boot();
      addTearDown(h.dispose);

      await h.controller.importVoiceprint(_spkemb());
      await h.controller.start();
      expect(h.segmenter.gateAttachCount, 1);

      await h.controller.removeVoiceprint();
      expect(h.segmenter.gateDetachCount, 1);
      expect(h.controller.hasVoiceprint, isFalse);
    });

    test('被滤掉的段只记元数据，不进消息流', () async {
      final h = await _boot();
      addTearDown(h.dispose);
      await h.controller.importVoiceprint(_spkemb());
      await h.controller.start();

      // 回调是 feed 的时候递进来的，先喂一帧。
      h.engine.micCtrl.add(Uint8List(1920));
      await pumpEventQueue();

      h.segmenter.emitFiltered(
        const FilteredSegment(
          startMs: 1000,
          endMs: 2000,
          durationMs: 1000,
          pvadScore: 0.02,
          pvadTargetRatio: 0.0,
        ),
      );
      await pumpEventQueue();

      expect(h.controller.messages, isEmpty, reason: '别人的话不该进历史');
      expect(
        h.controller.log.map((e) => e.message).join('\n'),
        contains('说话人不是本人'),
      );
    });
  });
}

class _Harness {
  _Harness(this.controller, this.segmenter, this.engine);

  final ConversationController controller;
  final FakeSegmenter segmenter;
  final FakeVoiceEngine engine;

  Future<void> dispose() async {
    await controller.stop();
    controller.dispose();
    engine.close();
  }
}

/// 起一个能用声纹的 controller。**不注入 history**：注入之后
/// `_appRoot` 不会被解析，声纹存储就没有目录可用 —— 这里要的正是
/// 真实目录那条路径，所以给一个临时目录让它自己建。
Future<_Harness> _boot({
  double threshold = 0.5,
  double minRatio = 0.5,
  bool pvadEnabled = true,
}) async {
  final root = await Directory.systemTemp.createTemp('vp_ctrl');
  addTearDown(() => root.delete(recursive: true));

  final engine = FakeVoiceEngine();
  final segmenter = FakeSegmenter();
  final brain = BrainClient(
    client: MockClient((request) async => http.Response('', 503)),
  );

  final controller = ConversationController(
    engine: engine,
    brain: brain,
    appDir: () async => root,
    segmenterFactory:
        ({required int sampleRate, required AssistantConfig config}) async {
          return segmenter;
        },
  );

  await controller.updateConfig(
    configWithBrain(
      const BrainConfig(baseUrl: 'http://test.local:8000', brainId: '测试'),
    ).copyWith(
      pvadEnabled: pvadEnabled,
      pvadThreshold: threshold,
      pvadMinTargetRatio: minRatio,
    ),
  );

  return _Harness(controller, segmenter, engine);
}
