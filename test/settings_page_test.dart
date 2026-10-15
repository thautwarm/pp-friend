import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/brain/brain_client.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/ui/settings_page.dart';

import 'support/avatar_fakes.dart';
import 'support/voice_fakes.dart';

AssistantConfig _twoProfiles() => const AssistantConfig(
      profiles: [
        Profile(
          id: 'p_a',
          name: 'A',
          brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'a'),
        ),
        Profile(
          id: 'p_b',
          name: 'B',
          brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'b'),
        ),
      ],
      focusedProfileId: 'p_a',
    );

/// 全程不碰磁盘：历史走内存、头像走假的。
///
/// **不能给它真的 appDir。** `testWidgets` 把测试体跑在假时钟里，真实的
/// 异步文件 IO 在那里永远不会完成 —— 测试不是失败，是直接挂死，
/// 连 `--timeout` 都救不了（超时靠定时器，定时器也在假时钟里）。
Future<(ConversationController, FakeAvatarStore)> _boot() async {
  final avatars = FakeAvatarStore();
  final controller = ConversationController(
    engine: FakeVoiceEngine(),
    brainFactory: () => BrainClient(
      client: MockClient((_) async => throw StateError('不该发请求')),
    ),
    history: MemoryMessageStore(),
    avatars: avatars,
    segmenterFactory:
        ({required int sampleRate, required AssistantConfig config}) async =>
            FakeSegmenter(),
  );
  await controller.updateConfig(_twoProfiles());
  return (controller, avatars);
}

Future<void> _pump(WidgetTester tester, ConversationController controller) async {
  await tester.pumpWidget(
    MaterialApp(home: SettingsPage(controller: controller)),
  );
  await tester.pumpAndSettle();
}

Profile _profile(ConversationController c, String id) =>
    c.config.profiles.firstWhere((p) => p.id == id);

/// 按标签找输入框。比按下标找稳 —— 页面上本来就有一堆 TextField。
Finder _field(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextField));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('顶层是两个 tab：档案 / 断句参数', (tester) async {
    final (controller, _) = await _boot();
    addTearDown(controller.dispose);

    await _pump(tester, controller);

    expect(find.text('档案'), findsOneWidget);
    expect(find.text('断句参数'), findsOneWidget);
    // 默认停在档案 tab
    expect(_field('Base URL'), findsOneWidget);

    await tester.tap(find.text('断句参数'));
    await tester.pumpAndSettle();
    expect(_field('静音判定 (ms)'), findsOneWidget);
  });

  testWidgets('点另一个档案的 tab，就切到它的设置', (tester) async {
    final (controller, _) = await _boot();
    addTearDown(controller.dispose);

    await _pump(tester, controller);
    // 一开始是 A：它的 brain_id 显示在输入框里
    expect(find.text('a'), findsOneWidget);

    // chip 里有两个字 "B"：头像里的首字和名字。点哪个都落在同一个 chip 上，
    // 取后一个（名字）更稳。
    await tester.tap(find.text('B').last);
    await tester.pumpAndSettle();

    expect(find.text('b'), findsOneWidget, reason: '切过去看到的是 B 的配置');
    expect(find.text('a'), findsNothing, reason: 'A 的输入框不该还留着');
  });

  testWidgets('切档案之前会把这一屏的改动落盘', (tester) async {
    final (controller, _) = await _boot();
    addTearDown(controller.dispose);

    await _pump(tester, controller);
    await tester.enterText(_field('名字'), '改过的名字');
    await tester.pump();

    // 没按保存，直接切走
    await tester.tap(find.text('B').last);
    await tester.pumpAndSettle();

    expect(_profile(controller, 'p_a').name, '改过的名字',
        reason: '切走不落盘的话，用户敲进去的字就无声无息地没了');
  });

  testWidgets('保存会写字段，也会把"去掉头像"落地成删文件', (tester) async {
    final (controller, avatars) = await _boot();
    addTearDown(controller.dispose);

    // 先让它"有一个头像"：配置里记着文件名，假存储里也有这个文件
    const oldName = 'p_a_0.png';
    avatars.files[oldName] = '图';
    await controller.saveProfile(
      _profile(controller, 'p_a').copyWith(avatarFile: oldName),
    );

    await _pump(tester, controller);
    expect(find.text('去掉'), findsOneWidget, reason: '有头像才显示"去掉"');

    await tester.tap(find.text('去掉'));
    await tester.pumpAndSettle();
    expect(find.text('选头像'), findsOneWidget, reason: '按了去掉就变回"选头像"');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(_profile(controller, 'p_a').avatarFile, isNull);
    expect(avatars.removed, contains(oldName),
        reason: '配置里不引用了，文件也得删 —— 不然每换一次就多一份永久垃圾');
    expect(avatars.files.containsKey(oldName), isFalse);
  });

  testWidgets('加号新建一个档案，并且立刻选中它', (tester) async {
    final (controller, _) = await _boot();
    addTearDown(controller.dispose);

    await _pump(tester, controller);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(controller.config.profiles.length, 3);
    expect(find.text('新档案'), findsWidgets);
    // 新档案还没填 brain，所以 Base URL 框是空的
    expect(tester.widget<TextField>(_field('Base URL')).controller?.text, '');
  });

  testWidgets('关着的档案在一排 tab 里看得出来', (tester) async {
    final (controller, _) = await _boot();
    addTearDown(controller.dispose);
    final b = _profile(controller, 'p_b');
    await controller.saveProfile(b.copyWith(enabled: false));

    await _pump(tester, controller);

    // 不用 find.bySemanticsLabel：那需要先 ensureSemantics，而这里要验的
    // 本来就是"那个图标在不在、它有没有说自己是关闭"
    final icon = tester.widget<Icon>(find.byIcon(Icons.power_settings_new));
    expect(icon.semanticLabel, '已关闭',
        reason: '一排 tab 里得一眼看出哪个是关着的');
  });

  testWidgets('头像文件不见了也不会把设置页搞崩', (tester) async {
    final (controller, avatars) = await _boot();
    addTearDown(controller.dispose);
    // 配置里记着文件名，但假存储里没有这个文件 —— 文件被系统清掉的样子
    await controller.saveProfile(
      _profile(controller, 'p_a').copyWith(avatarFile: 'p_a_不见了.png'),
    );

    await _pump(tester, controller);

    expect(tester.takeException(), isNull);
    expect(find.text('A'), findsWidgets, reason: '页面照常，chip 上退回那个字');
    expect(avatars.files, isEmpty);
  });
}
