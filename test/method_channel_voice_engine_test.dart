import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pp_friend/src/voice/method_channel_voice_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('pp_friend/voice_engine');
  late List<MethodCall> calls;

  setUp(() {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'probeLocalNetwork') return 'ready';
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  MethodCall? probeCall() {
    final matches = calls.where((c) => c.method == 'probeLocalNetwork');
    return matches.isEmpty ? null : matches.last;
  }

  test('内网 IP 会先探测一次，把本地网络授权框逼出来', () async {
    final engine = MethodChannelVoiceEngine();
    await engine.prepareNetworkAccess('http://192.168.0.102:18781');

    final call = probeCall();
    expect(call, isNotNull);
    expect(call!.arguments['host'], '192.168.0.102');
    expect(call.arguments['port'], 18781);
    expect(call.arguments['timeoutMs'], isA<int>());
  });

  test('公网地址不探测，免得每次启动都多一次 TCP 连接', () async {
    final engine = MethodChannelVoiceEngine();
    await engine.prepareNetworkAccess('https://brain.example.com');

    expect(probeCall(), isNull);
  });

  test('localhost 和 .local 都算本地网络', () async {
    final engine = MethodChannelVoiceEngine();
    await engine.prepareNetworkAccess('http://localhost:8080');
    await engine.prepareNetworkAccess('http://brain.local:9000');

    final probes = calls
        .where((c) => c.method == 'probeLocalNetwork')
        .toList();
    expect(probes, hasLength(2));
    expect(probes[0].arguments['host'], 'localhost');
    expect(probes[1].arguments['host'], 'brain.local');
  });

  test('没写端口时按 scheme 补 80 / 443', () async {
    final engine = MethodChannelVoiceEngine();
    await engine.prepareNetworkAccess('http://10.0.0.2');
    await engine.prepareNetworkAccess('https://10.0.0.3');

    final probes = calls
        .where((c) => c.method == 'probeLocalNetwork')
        .toList();
    expect(probes[0].arguments['port'], 80);
    expect(probes[1].arguments['port'], 443);
  });

  test('原生端没实现这个方法时静默放过，不阻塞会话', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);

    final engine = MethodChannelVoiceEngine();
    await engine.prepareNetworkAccess('http://192.168.0.102:18781');
  });

  test('探测失败不抛给调用方', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'probeFailed');
        });

    final engine = MethodChannelVoiceEngine();
    await engine.prepareNetworkAccess('http://192.168.0.102:18781');
  });
}
