import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/brain/brain_client.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/ui/onboarding_page.dart';
import 'package:pp_friend/src/voice/mic_permission.dart';
import 'package:pp_friend/src/voice/network_check.dart';

import 'support/avatar_fakes.dart';
import 'support/test_app.dart';
import 'support/voice_fakes.dart';

const _channel = MethodChannel('pp_friend/voice_engine');

AssistantConfig _withBrain({String baseUrl = 'http://192.168.0.102:18781'}) =>
    AssistantConfig(
      profiles: [
        Profile(
          id: 'p_a',
          name: 'A',
          brain: BrainConfig(baseUrl: baseUrl, brainId: 'a'),
        ),
      ],
      focusedProfileId: 'p_a',
    );

Future<ConversationController> _boot([AssistantConfig? config]) async {
  final controller = ConversationController(
    engine: FakeVoiceEngine(),
    brainFactory: () =>
        BrainClient(client: MockClient((_) async => throw StateError('不该发请求'))),
    history: MemoryMessageStore(),
    avatars: FakeAvatarStore(),
    segmenterFactory: ({
      required int sampleRate,
      required AssistantConfig config,
    }) async => FakeSegmenter(),
  );
  await controller.updateConfig(config ?? _withBrain());
  return controller;
}

/// 页面比默认的 800×600 高，矮屏幕上按钮会被 ListView 懒加载掉、找不到。
void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls = <MethodCall>[];
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  void mockNative({
    String micStatus = 'authorized',
    String probe = 'ready',
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'micPermissionStatus' => micStatus,
            'probeLocalNetwork' => probe,
            'requestMicPermission' => true,
            'openMicSettings' || 'openLocalNetworkSettings' => true,
            _ => null,
          };
        });
  }

  testWidgets('全部检查通过之后才能继续', (tester) async {
    _tall(tester);
    mockNative();
    final controller = await _boot();
    addTearDown(controller.dispose);
    var done = false;

    await tester.pumpWidget(
      testApp(
        OnboardingPage(
          controller: controller,
          firstRun: true,
          onDone: () => done = true,
          httpChecker: (_) async => const BrainHttpCheck.ok(404),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('麦克风'), findsOneWidget);
    expect(find.text('已允许'), findsOneWidget);
    expect(find.text('本地网络'), findsOneWidget);
    expect(find.text('已允许，能连上 brain'), findsOneWidget);
    expect(find.text('HTTP 已连通（404）'), findsOneWidget);

    final probe = calls.firstWhere((c) => c.method == 'probeLocalNetwork');
    expect(probe.arguments['host'], '192.168.0.102');
    expect(probe.arguments['port'], 18781);

    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();

    expect(done, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(onboardingDonePrefKey), isTrue);
  });

  testWidgets('HTTP 不通时继续按钮不可点', (tester) async {
    _tall(tester);
    mockNative();
    final controller = await _boot();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      testApp(
        OnboardingPage(
          controller: controller,
          httpChecker: (_) async =>
              const BrainHttpCheck.failed('SocketException: Connection refused'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('连接失败'), findsWidgets);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '开始使用'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('改地址并保存会写进当前档案', (tester) async {
    _tall(tester);
    mockNative();
    final controller = await _boot();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      testApp(
        OnboardingPage(
          controller: controller,
          httpChecker: (_) async => const BrainHttpCheck.ok(200),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'http://192.168.0.102:18781'),
      'http://10.0.0.9:8000',
    );
    await tester.tap(find.text('保存并检测'));
    await tester.pumpAndSettle();

    expect(controller.config.brain.baseUrl, 'http://10.0.0.9:8000');
  });

  testWidgets('没填 brain 时不探测，给出去设置的入口', (tester) async {
    _tall(tester);
    mockNative();
    final controller = await _boot(
      const AssistantConfig(
        profiles: [
          Profile(id: 'p_a', name: 'A', brain: BrainConfig()),
        ],
        focusedProfileId: 'p_a',
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(testApp(OnboardingPage(controller: controller)));
    await tester.pumpAndSettle();

    expect(find.text('先填 Base URL 和 brain_id'), findsOneWidget);
    expect(calls.where((c) => c.method == 'probeLocalNetwork'), isEmpty);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '开始使用'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('探测失败时提示未允许，并给系统设置入口', (tester) async {
    _tall(tester);
    mockNative(probe: 'failed');
    final controller = await _boot();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      testApp(
        OnboardingPage(
          controller: controller,
          httpChecker: (_) async => const BrainHttpCheck.ok(404),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('未允许，或者 brain 连不上'), findsOneWidget);

    await tester.tap(find.text('打开系统设置').last);
    await tester.pumpAndSettle();
    expect(
      calls.where((c) => c.method == 'openLocalNetworkSettings'),
      hasLength(1),
    );
  });

  testWidgets('当前平台不需要本地网络时隐藏这一行', (tester) async {
    _tall(tester);
    final controller = await _boot();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      testApp(
        OnboardingPage(
          controller: controller,
          micStatusLoader: () async => MicPermissionState.unknown,
          localStatusLoader: (_) async => LocalNetworkState.unsupported,
          httpChecker: (_) async => const BrainHttpCheck.ok(404),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('麦克风'), findsOneWidget);
    expect(find.text('本地网络'), findsNothing);
  });
}
