import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pp_friend/src/voice/mic_permission.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('pp_friend/voice_engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('原生通道给了结果就直接用，不再碰 permission_handler', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      expect(call.method, 'requestMicPermission');
      return true;
    });

    expect(await requestMicPermission(), isTrue);
    expect(calls, 1);
  });

  test('原生通道拒绝时返回 false', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    expect(await requestMicPermission(), isFalse);
  });
}
