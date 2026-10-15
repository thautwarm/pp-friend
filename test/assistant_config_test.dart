import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:pp_friend/src/config/assistant_config.dart';

void main() {
  group('AssistantConfig 序列化', () {
    test('新字段全部往返', () {
      const config = AssistantConfig(
        profiles: [
          Profile(
            id: AssistantConfig.defaultProfileId,
            name: '员工3',
            brain: BrainConfig(
              baseUrl: 'http://192.168.0.9:8000',
              brainId: '员工3',
              token: 'secret',
            ),
          ),
        ],
        vadThreshold: 0.42,
        vadMinSilenceMs: 900,
        vadSpeechPadMs: 260,
        vadMinSpeechMs: 400,
        vadMaxSpeechS: 35,
        vadRingCapacityMs: 45000,
        bargeIn: true,
      );

      // 走一遍真正的 JSON 编码，而不是直接塞 map ——
      // 类型在编码后可能变（int/double），序列化 bug 往往就藏在那里。
      final restored = AssistantConfig.fromJson(
        (jsonDecode(jsonEncode(config.toJson())) as Map).cast<String, dynamic>(),
      );

      expect(restored.brain.baseUrl, config.brain.baseUrl);
      expect(restored.brain.brainId, config.brain.brainId);
      expect(restored.brain.token, config.brain.token);
      expect(restored.vadThreshold, closeTo(0.42, 1e-9));
      expect(restored.vadMinSilenceMs, 900);
      expect(restored.vadSpeechPadMs, 260);
      expect(restored.vadMinSpeechMs, 400);
      expect(restored.vadMaxSpeechS, 35);
      expect(restored.vadRingCapacityMs, 45000);
      expect(restored.bargeIn, isTrue);
    });

    test('老 JSON（只有 vadSilenceMs）能读，且不丢 brain 配置', () {
      // 存储 key 是 assistant_config_v1，用户手机上真的有这种 JSON。
      // 换 key 或者不认旧字段，都会把人家的 baseUrl/token 静默清空。
      const legacy = '''
      {
        "brain": {
          "baseUrl": "http://192.168.0.100:8000",
          "brainId": "员工3",
          "token": "abc"
        },
        "vadSilenceMs": 1200
      }
      ''';

      final config = AssistantConfig.fromJson(
        (jsonDecode(legacy) as Map).cast<String, dynamic>(),
      );

      expect(config.brain.baseUrl, 'http://192.168.0.100:8000');
      expect(config.brain.brainId, '员工3');
      expect(config.brain.token, 'abc');
      // 旧值必须当成本次的静音判定继承下来，不能原地弹回默认
      expect(config.vadMinSilenceMs, 1200);
      // 旧版本没有的字段走默认
      expect(config.vadThreshold, 0.5);
      expect(config.vadSpeechPadMs, 200);
    });

    test('空 JSON 全是默认值', () {
      final config = AssistantConfig.fromJson(const <String, dynamic>{});
      expect(config.brain.isUsable, isFalse);
      expect(config.vadThreshold, 0.5);
      expect(config.vadMinSilenceMs, 1000);
      expect(config.vadMinSpeechMs, 300);
      expect(config.vadMaxSpeechS, 60);
      // 打断默认必须关：那是 handoff §A5 的"收到就播，不做自动打断"。
      // 老 JSON 里没有这个键，必须落在这个默认值上。
      expect(config.bargeIn, isFalse);
      // 环形缓冲必须装得下最长的一段，否则正在说的那段会被自己挤掉
      expect(
        config.vadRingCapacityMs,
        greaterThan(config.vadMaxSpeechS * 1000),
      );
    });

    test('copyWith 只改指定的字段', () {
      const config = AssistantConfig(
        profiles: [
          Profile(
            id: AssistantConfig.defaultProfileId,
            brain: BrainConfig(baseUrl: 'u', brainId: 'b'),
          ),
        ],
        vadMinSilenceMs: 800,
      );
      final updated = config.copyWith(vadThreshold: 0.7);
      expect(updated.vadThreshold, 0.7);
      expect(updated.vadMinSilenceMs, 800);
      expect(updated.brain.baseUrl, 'u');
    });
  });
}
