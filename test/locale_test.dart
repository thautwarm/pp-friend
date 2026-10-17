import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pp_friend/l10n/app_localizations.dart';
import 'package:pp_friend/src/config/assistant_config.dart';
import 'package:pp_friend/src/conversation/conversation_controller.dart';
import 'package:pp_friend/src/i18n/locale_controller.dart';
import 'package:pp_friend/src/storage/memory_message_store.dart';
import 'package:pp_friend/src/ui/settings_page.dart';

import 'support/voice_fakes.dart';

/// 跟 `main.dart` 一样接：provider 提供语言，Consumer 把它塞进 MaterialApp。
/// 固定 `locale` 的 `testApp` 在这里没有意义 —— 要验的就是它会不会变。
Widget _wire(LocaleController locale, Widget home) {
  return ChangeNotifierProvider.value(
    value: locale,
    child: Consumer<LocaleController>(
      builder: (context, value, _) => MaterialApp(
        locale: value.locale,
        supportedLocales: LocaleController.supported,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: home,
      ),
    ),
  );
}

Future<ConversationController> _boot() async {
  final controller = ConversationController(
    engine: FakeVoiceEngine(),
    history: MemoryMessageStore(),
  );
  await controller.updateConfig(
    const AssistantConfig(
      profiles: [
        Profile(
          id: 'p_a',
          name: 'A',
          brain: BrainConfig(baseUrl: 'http://test.local:8000', brainId: 'a'),
        ),
      ],
      focusedProfileId: 'p_a',
    ),
  );
  return controller;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('选过的语言会记住，跟随系统会把这个偏好删掉', () async {
    final controller = LocaleController();
    await controller.load();
    expect(controller.locale, isNull, reason: '第一次启动应该跟随系统');

    await controller.select('en');
    expect(controller.locale, const Locale('en'));

    final restored = LocaleController();
    await restored.load();
    expect(restored.locale, const Locale('en'), reason: '重启后得还是英文');

    // 回“跟随系统”不能留下一个 en 的残留，否则系统换成中文它也还是英文
    await restored.select(LocaleController.systemValue);
    expect(restored.locale, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ui_locale_v1'), isNull);
  });

  testWidgets('通用里切成英文，界面立刻变英文', (tester) async {
    final controller = await _boot();
    addTearDown(controller.dispose);
    final locale = LocaleController();
    await locale.select('zh');

    await tester.pumpWidget(
      _wire(locale, SettingsPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('档案'), findsOneWidget);
    await tester.tap(find.text('通用'));
    await tester.pumpAndSettle();
    expect(find.text('语言'), findsOneWidget);

    // 下拉框当前显示“中文”（上面已选成 zh）
    await tester.tap(find.text('中文'));
    await tester.pumpAndSettle();
    // 菜单里 English 和当前选中项之外可能重复，点最后一个（菜单项）
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();

    expect(locale.locale, const Locale('en'));
    expect(find.text('Language'), findsOneWidget, reason: '这一节标题该跟着变');
    expect(find.text('General'), findsWidgets);
    expect(find.text('语言'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('ui_locale_v1'), 'en');

    // 日语也是同样一条路：下拉框里必须能选到，界面跟着换
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日本語').last);
    await tester.pumpAndSettle();

    expect(locale.locale, const Locale('ja'));
    expect(find.text('言語'), findsOneWidget);
    expect(find.text('一般'), findsWidgets);
    expect(find.text('Language'), findsNothing);
    expect(prefs.getString('ui_locale_v1'), 'ja');
  });
}
