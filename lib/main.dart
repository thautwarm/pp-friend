import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'l10n/app_localizations.dart';
import 'src/conversation/conversation_controller.dart';
import 'src/i18n/locale_controller.dart';
import 'src/ui/home_page.dart';
import 'src/ui/onboarding_page.dart';
import 'src/voice/mic_permission.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 首次启动先过一遍权限检查：麦克风和 macOS 的本地网络都不是"点了就会
  // 自动有"的东西，让用户自己去找系统设置太难了。
  var onboardingDone = false;
  try {
    onboardingDone = await onboardingCompleted();
  } catch (_) {
    // 读不到就当没做过，宁可多看一页也不要把人挡在权限问题外面。
  }
  runApp(PpFriendApp(showOnboarding: !onboardingDone));
}

class PpFriendApp extends StatefulWidget {
  const PpFriendApp({super.key, this.showOnboarding = false});

  /// 首次启动。完成引导后切到主界面。
  final bool showOnboarding;

  @override
  State<PpFriendApp> createState() => _PpFriendAppState();
}

class _PpFriendAppState extends State<PpFriendApp> {
  late final ConversationController _controller;
  late final LocaleController _locale;
  late bool _showOnboarding = widget.showOnboarding;

  static const _seed = Color(0xFF5B6ABF);

  @override
  void initState() {
    super.initState();
    _controller = ConversationController()
      ..permissionGate = _requestPermissions;
    // 配置是异步读的，先渲染再补上，避免卡在启动画面
    _controller.loadConfig();
    // 语言也是异步读的；读回来之前先用系统语言，不会闪一下空白。
    _locale = LocaleController()..load();
  }

  @override
  void dispose() {
    _locale.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 麦克风必须给；通知在 Android 13+ 决定前台服务那条常驻通知能否显示，
  /// 被拒绝也不阻断 —— 服务照样跑，只是通知栏看不到。
  Future<bool> _requestPermissions() async {
    if (!await requestMicPermission()) return false;

    await requestNotificationPermissionIfSupported();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // provider 只管“当前选了什么语言”；真正的文案在 gen-l10n 生成的
    // AppLocalizations 里。两者拆开是因为 MaterialApp 必须整棵重建才
    // 能换语言，而 provider 正好负责通知。
    return ChangeNotifierProvider.value(
      value: _locale,
      child: Consumer<LocaleController>(
        builder: (context, locale, _) => MaterialApp(
          title: 'PP Friend',
          debugShowCheckedModeBanner: false,
          locale: locale.locale,
          supportedLocales: LocaleController.supported,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          theme: ThemeData(colorSchemeSeed: _seed, useMaterial3: true),
          darkTheme: ThemeData(
            colorSchemeSeed: _seed,
            brightness: Brightness.dark,
            useMaterial3: true,
          ),
          home: _showOnboarding
              ? OnboardingPage(
                  controller: _controller,
                  firstRun: true,
                  onDone: () => setState(() => _showOnboarding = false),
                )
              : HomePage(controller: _controller),
        ),
      ),
    );
  }
}
