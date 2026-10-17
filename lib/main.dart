import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import 'l10n/app_localizations.dart';
import 'src/conversation/conversation_controller.dart';
import 'src/i18n/locale_controller.dart';
import 'src/ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PpFriendApp());
}

class PpFriendApp extends StatefulWidget {
  const PpFriendApp({super.key});

  @override
  State<PpFriendApp> createState() => _PpFriendAppState();
}

class _PpFriendAppState extends State<PpFriendApp> {
  late final ConversationController _controller;
  late final LocaleController _locale;

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
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) return false;

    await Permission.notification.request();
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
          home: HomePage(controller: _controller),
        ),
      ),
    );
  }
}
