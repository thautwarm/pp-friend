import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/conversation/message.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/ui/home_page.dart';

import 'support/test_app.dart';
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

Future<ConversationController> _boot(MemoryMessageStore store) async {
  final controller = ConversationController(
    engine: FakeVoiceEngine(),
    history: store,
    appDir: () async => null,
  );
  await controller.updateConfig(_twoProfiles());
  return controller;
}

/// 主界面里那个说话按钮一直在呼吸（无限动画），
/// 所以**不能用 pumpAndSettle** —— 它永远等不到静止，会直接超时。
Future<void> _settle(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> _pumpHome(WidgetTester tester, ConversationController c) async {
  await tester.pumpWidget(testApp(HomePage(controller: c)));
  await _settle(tester);
}

/// 消息列表的滚动位置。
///
/// 不能直接 `find.byType(Scrollable)` —— 说话按钮那条档案带是个 [PageView]，
/// 它自己也是个 Scrollable，会先被找到。
ScrollPosition _listPosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      ),
    )
    .position;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('有历史就直接显示，不显示"直接说话就行"', (tester) async {
    final store = MemoryMessageStore();
    await store.append('p_a', role: MessageRole.user, text: '我上次说的');
    await store.append('p_a', role: MessageRole.assistant, text: '它上次回的');
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    expect(find.text('我上次说的'), findsOneWidget);
    expect(find.text('它上次回的'), findsOneWidget);
    expect(find.text('直接说话就行'), findsNothing);
  });

  testWidgets('没历史才显示引导语', (tester) async {
    final controller = await _boot(MemoryMessageStore());
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    // 没开始对话，所以是"开始之后…"那句
    expect(find.text('开始之后，你和它说的话都会出现在这里'), findsOneWidget);
  });

  testWidgets('点箭头切档案，整屏换成新档案的历史', (tester) async {
    final store = MemoryMessageStore();
    await store.append('p_a', role: MessageRole.user, text: 'A 说的话');
    await store.append('p_b', role: MessageRole.user, text: 'B 说的话');
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);
    expect(find.text('A 说的话'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await _settle(tester, 12);

    expect(controller.config.focusedProfileId, 'p_b');
    expect(find.text('B 说的话'), findsOneWidget);
    expect(find.text('A 说的话'), findsNothing, reason: '一个档案一屏历史，不混在一起');
  });

  testWidgets('往上翻会加载更早的历史，加载完之后视野不跳', (tester) async {
    final store = MemoryMessageStore();
    // 超过内存窗口（300 条）才谈得上分页
    for (var i = 1; i <= 340; i++) {
      await store.append('p_a', role: MessageRole.user, text: '第 $i 条');
    }
    final controller = await _boot(store);
    addTearDown(controller.dispose);

    await _pumpHome(tester, controller);

    // 打开时载入的是最近的 300 条（第 41~340 条）
    expect(find.text('第 340 条'), findsOneWidget);
    expect(controller.hasMoreBefore, isTrue);

    // 拖一次就到顶，而且拖动距离给得比内容总高度还大，所以一定停在 pixels = 0。
    // （drag 是按给定距离滚动的，不是滚到尽头 —— 给 20000 会停在离顶 1676px 处，
    //   那样根本触发不了加载。）
    final maxBefore = _listPosition(tester).maxScrollExtent;
    await tester.drag(find.byType(ListView), const Offset(0, 30000));
    await _settle(tester, 6);

    expect(
      controller.messages.length,
      greaterThan(300),
      reason: '翻到顶就该去读更早的那一页',
    );
    expect(controller.messages.first.seq, 1);
    expect(
      controller.messages.map((m) => m.seq).toSet().length,
      controller.messages.length,
      reason: '不重不漏',
    );

    // 往前面插 40 条会让内容变高。不补偿滚动位置的话 pixels 还停在 0，
    // 用户会瞬间被弹到最开头。
    final position = _listPosition(tester);
    final grew = position.maxScrollExtent - maxBefore;
    expect(grew, greaterThan(0));
    expect(
      position.pixels,
      closeTo(grew, 1),
      reason:
          '补了正好"新插进来那些的高度"：插进来的应该在视野上面，'
          '而不是把当前视野挤走',
    );
  });
}
